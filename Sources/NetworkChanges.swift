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
    private var wifiEvents: [CWEventType] = []
    private var onChange: (@MainActor (Bool) -> Void)?
    private var pathSignature: String?
    private var configuration: NSDictionary?
    private var connected: Bool?
    private var lastDelivered: Bool?
    private var pending: Timer?

    private static let keys = [
        "State:/Network/Global/IPv4", "State:/Network/Global/IPv6", "State:/Network/Global/DNS",
    ]
    private static let patterns = [
        "State:/Network/Service/.*/IPv4", "State:/Network/Service/.*/IPv6", "State:/Network/Service/.*/DNS",
        "State:/Network/Interface/.*/Link",
    ]

    private static let notificationPatterns = patterns + ["State:/Network/Interface/.*/AirPort"]

    func start(onChange: @escaping @MainActor (Bool) -> Void) {
        stop()
        self.onChange = onChange
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
            { _, changedKeys, info in
                guard let info else { return }
                MainActor.assumeIsolated {
                    Unmanaged<NetworkChanges>.fromOpaque(info).takeUnretainedValue().configurationChanged(
                        changedKeys as? [String] ?? [])
                }
            }, &context)
        if let store {
            configuration = SCDynamicStoreCopyMultiple(store, Self.keys as CFArray, Self.patterns as CFArray)
            SCDynamicStoreSetNotificationKeys(store, Self.keys as CFArray, Self.notificationPatterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        let wifi = CWWiFiClient()
        self.wifi = wifi
        wifi.delegate = self
        for event: CWEventType in [.powerDidChange, .linkDidChange, .ssidDidChange, .bssidDidChange] {
            do {
                try wifi.startMonitoringEvent(with: event)
                wifiEvents.append(event)
            } catch {
                // Path and configuration notifications remain available if Wi-Fi events are restricted.
            }
        }
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
            for event in wifiEvents { try? wifi.stopMonitoringEvent(with: event) }
        }
        wifi = nil
        wifiEvents = []
        onChange = nil
        pathSignature = nil
        configuration = nil
        connected = nil
        lastDelivered = nil
    }

    private func pathChanged(_ path: NWPath) {
        let interfaces = path.availableInterfaces.map { "\($0.name):\($0.type)" }.sorted().joined(separator: ",")
        let signature = "\(path.status)|\(interfaces)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.supportsDNS)"
        guard signature != pathSignature else { return }
        pathSignature = signature
        // An on-demand VPN may need an outgoing request to establish its connection.
        connected = path.status != .unsatisfied
        scheduleChange()
    }

    private func configurationChanged(_ changedKeys: [String]) {
        guard let store else { return }
        let next: NSDictionary? = SCDynamicStoreCopyMultiple(store, Self.keys as CFArray, Self.patterns as CFArray)
        guard next != configuration || changedKeys.contains(where: { $0.hasSuffix("/AirPort") }) else { return }
        configuration = next
        scheduleChange()
    }

    private func scheduleChange() {
        guard let connected, onChange != nil else { return }
        pending?.invalidate()
        pending = nil
        if !connected {
            guard lastDelivered != false else { return }
            lastDelivered = false
            onChange?(false)
            return
        }
        // DHCP, DNS, the default route and Wi-Fi can each announce the same switch.
        let timer = Timer(timeInterval: 0.75, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.lastDelivered = self.connected == true
                self.onChange?(self.connected == true)
            }
        }
        pending = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }
    nonisolated func bssidDidChangeForWiFiInterface(withName interfaceName: String) { wifiChanged() }

    nonisolated private func wifiChanged() {
        Task { @MainActor [weak self] in self?.scheduleChange() }
    }
}
