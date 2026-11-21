import CoreWLAN
import Foundation
import Network
import SystemConfiguration

/// Observes network readiness and network switches without reading Wi-Fi identifiers.
@MainActor
final class NetworkChanges: NSObject, CWEventDelegate {
    private var monitor: NWPathMonitor?
    private var store: SCDynamicStore?
    private var wifi: CWWiFiClient?
    var onChange: (@MainActor (Bool) -> Void)?
    private struct Signature: Equatable {
        var connected: Bool?
        var interfaceTypes = Set<NWInterface.InterfaceType>()
        var routes: [Route] = []
    }

    private struct Route: Equatable {
        let interface: String?
        let service: String?
        let router: String?

        init(_ fields: [String: Any]?) {
            interface = fields?["PrimaryInterface"] as? String
            service = fields?["PrimaryService"] as? String
            router = fields?["Router"] as? String
        }
    }

    private var current = Signature()
    private var wifiCandidates = Set<String>()
    private var otherInterfaces = Set<String>()
    private var delivered: Signature?
    private var pendingSSIDInterfaces = Set<String>()
    private var pending: Timer?

    private static let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]

    func start() {
        stop()
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor, self.monitor === monitor else { return }
                self.pathChanged(path)
            }
        }

        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        store = SCDynamicStoreCreate(
            nil, "QuotaBar Network Changes" as CFString,
            { _, _, info in
                guard let info else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NetworkChanges>.fromOpaque(info).takeUnretainedValue().readRoutes()
                }
            }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, Self.keys as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, .main)
            readRoutes()
        }
        let wifi = CWWiFiClient()
        self.wifi = wifi
        wifi.delegate = self
        // A change of access point within one Wi-Fi network does not change provider access.
        try? wifi.startMonitoringEvent(with: .ssidDidChange)
        monitor.start(queue: .main)
    }

    func stop() {
        pending?.invalidate()
        pending = nil
        monitor?.cancel()
        monitor = nil
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        if let wifi {
            wifi.delegate = nil
            try? wifi.stopMonitoringEvent(with: .ssidDidChange)
        }
        wifi = nil
        current = Signature()
        wifiCandidates = []
        otherInterfaces = []
        delivered = nil
        pendingSSIDInterfaces.removeAll()
    }

    private func pathChanged(_ path: NWPath) {
        let active = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
        // An on-demand VPN may need an outgoing request to establish its connection.
        updatePath(
            connected: path.status != .unsatisfied, interfaceTypes: Set(active.map(\.type)),
            wifiInterfaces: Set(active.filter { $0.type == .wifi }.map(\.name)),
            otherInterfaces: Set(path.availableInterfaces.filter { $0.type == .other }.map(\.name)))
    }

    func updatePath(
        connected: Bool, interfaceTypes: Set<NWInterface.InterfaceType>, wifiInterfaces: Set<String>,
        otherInterfaces: Set<String> = []
    ) {
        wifiCandidates = wifiInterfaces
        self.otherInterfaces = otherInterfaces
        guard current.connected != connected || current.interfaceTypes != interfaceTypes else { return }
        current.connected = connected
        current.interfaceTypes = interfaceTypes
        scheduleChange()
    }

    private func readRoutes() {
        guard let store, let values = SCDynamicStoreCopyMultiple(store, Self.keys as CFArray, nil) else { return }
        updateRoutes(values as NSDictionary)
    }

    func updateRoutes(_ values: NSDictionary) {
        let routes = Self.keys.map { Route(values[$0] as? [String: Any]) }
        guard routes != current.routes else { return }
        current.routes = routes
        scheduleChange()
    }

    private func scheduleChange() {
        guard let connected = current.connected, onChange != nil else { return }
        pending?.invalidate()
        pending = nil
        if !connected {
            pendingSSIDInterfaces.removeAll()
            guard delivered?.connected != false else { return }
            delivered = current
            onChange?(false)
            return
        }
        guard current != delivered || !pendingSSIDInterfaces.isEmpty else { return }
        // The route and Wi-Fi can announce the same switch. Deliver the settled state once.
        let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                let switched =
                    self.current != self.delivered || self.pendingSSIDInterfaces.contains(where: self.usesWifi)
                self.pendingSSIDInterfaces.removeAll()
                guard switched else { return }
                self.delivered = self.current
                self.onChange?(true)
            }
        }
        pending = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func usesWifi(_ interfaceName: String) -> Bool {
        guard current.connected == true, wifiCandidates.contains(interfaceName) else { return false }
        let routeInterfaces = current.routes.compactMap(\.interface)
        if routeInterfaces.contains(interfaceName) { return true }
        guard wifiCandidates.count == 1 else { return false }
        // A VPN can own the default route while Wi-Fi is its only physical transport.
        return routeInterfaces.isEmpty
            || (current.interfaceTypes.subtracting([.other]) == [.wifi]
                && routeInterfaces.allSatisfy(otherInterfaces.contains))
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            guard let self, usesWifi(interfaceName) else { return }
            pendingSSIDInterfaces.insert(interfaceName)
            scheduleChange()
        }
    }
}
