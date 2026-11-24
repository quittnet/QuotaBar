import CoreWLAN
import Foundation

@main @MainActor
enum NetworkSignalChecks {
    static func main() async throws {
        let monitor = NetworkChanges()
        var events: [Bool] = []
        monitor.onChange = { events.append($0) }
        defer { monitor.stop() }
        func route(_ router: String, interface: String = "en0", detail: Int = 0) -> NSDictionary {
            [
                "State:/Network/Global/IPv4": [
                    "PrimaryInterface": interface, "PrimaryService": "service", "Router": router, "Detail": detail,
                ],
                "State:/Network/Interface/en1/Link": ["Changed": detail],
            ]
        }
        func expect(_ expected: [Bool]) async throws {
            let limit = ContinuousClock.now.advanced(by: .seconds(5))
            while events.count < expected.count && ContinuousClock.now < limit {
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(events == expected, "Expected \(expected), received \(events)")
        }

        monitor.updateRoutes(route("router-a"))
        monitor.updatePath(connected: true, interfaceTypes: [.wifi], wifiInterfaces: ["en0"])
        try await expect([true])
        let wifi: CWEventDelegate = monitor
        wifi.linkDidChangeForWiFiInterface?(withName: "en0")
        wifi.bssidDidChangeForWiFiInterface?(withName: "en0")
        wifi.powerStateDidChangeForWiFiInterface?(withName: "en0")
        monitor.updatePath(connected: true, interfaceTypes: [.wifi], wifiInterfaces: ["en0", "en1"])
        wifi.ssidDidChangeForWiFiInterface?(withName: "en1")
        monitor.updateRoutes(route("router-a", detail: 1))
        monitor.updateRoutes(route("temporary"))
        monitor.updateRoutes(route("router-a"))
        try await Task.sleep(for: .seconds(1))
        try await expect([true])

        monitor.updateRoutes(route("router-b"))
        wifi.ssidDidChangeForWiFiInterface?(withName: "en0")
        try await expect([true, true])
        // Two networks can share a router address and use the same interface.
        wifi.ssidDidChangeForWiFiInterface?(withName: "en0")
        try await expect([true, true, true])
        monitor.updatePath(connected: false, interfaceTypes: [], wifiInterfaces: [])
        monitor.updatePath(connected: false, interfaceTypes: [], wifiInterfaces: [])
        try await expect([true, true, true, false])
        monitor.updatePath(connected: true, interfaceTypes: [.wiredEthernet], wifiInterfaces: [])
        try await expect([true, true, true, false, true])
        events.removeAll()
        monitor.updateRoutes(route("wired-router", interface: "en2"))
        monitor.updatePath(connected: true, interfaceTypes: [.wiredEthernet, .wifi], wifiInterfaces: ["en0"])
        try await expect([true])
        wifi.ssidDidChangeForWiFiInterface?(withName: "en0")
        try await Task.sleep(for: .seconds(1))
        try await expect([true])
        monitor.updateRoutes([:])
        wifi.ssidDidChangeForWiFiInterface?(withName: "en0")
        try await Task.sleep(for: .milliseconds(50))
        monitor.updateRoutes(route("wired-router", interface: "en2"))
        try await Task.sleep(for: .seconds(1))
        try await expect([true])
        monitor.updateRoutes(route("vpn-router", interface: "utun3"))
        monitor.updatePath(
            connected: true, interfaceTypes: [.wifi, .other], wifiInterfaces: ["en0"], otherInterfaces: ["utun3"])
        try await expect([true, true])
        wifi.ssidDidChangeForWiFiInterface?(withName: "en0")
        try await expect([true, true, true])
        monitor.updatePath(connected: false, interfaceTypes: [], wifiInterfaces: [])
        events.removeAll()
        monitor.updatePath(connected: true, interfaceTypes: [.wifi, .other], wifiInterfaces: ["en0"])
        for index in 0..<10 {
            monitor.updateRoutes(route("vpn-\(index)", interface: "utun3"))
            try await Task.sleep(for: .milliseconds(150))
        }
        precondition(events == [true], "Ongoing route updates must not postpone the reconnect signal")
        try await expect([true, true])
        monitor.updatePath(connected: false, interfaceTypes: [], wifiInterfaces: [])
        monitor.updatePath(connected: true, interfaceTypes: [.wifi], wifiInterfaces: ["en0"])
        monitor.updatePath(connected: false, interfaceTypes: [], wifiInterfaces: [])
        try await Task.sleep(for: .seconds(1))
        try await expect([true, true, false])
        print("Network signals ignored link and roaming noise and delivered switches, disconnect and reconnect.")
    }
}
