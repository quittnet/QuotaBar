import AppKit

@main
enum QuotaBar {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--capture-claude-quota"]) {
            let order = ClaudeQuotaSource.CaptureOrder.current()
            let observedAt = Date()
            guard ProviderSelection.saved(in: .standard) != .codex else { return }
            let environment = ProcessInfo.processInfo.environment
            guard environment["QUOTABAR_SKIP_NESTED_CAPTURE"] != "1" else { return }
            let path = [environment["QUOTABAR_CAPTURE_PROFILE"], environment["CLAUDE_CONFIG_DIR"]]
                .compactMap { $0 }.first { $0.hasPrefix("/") }
            let profile =
                path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
            let inherited = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            let file = ClaudeQuotaSource.cacheFile(for: profile, configuration: inherited)
            let payload: Data
            do {
                payload = try readStatusLine()
            } catch {
                try? ClaudeQuotaSource.invalidate(file: file, order: order, now: observedAt)
                exit(1)
            }
            do {
                try ClaudeQuotaSource.capture(statusLine: payload, file: file, order: order, now: observedAt)
                return
            } catch {
                exit(1)
            }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func readStatusLine() throws -> Data {
        let input = FileHandle.standardInput
        let maxBytes = 1024 * 1024
        var payload = Data()
        while let chunk = try input.read(upToCount: 16 * 1024), !chunk.isEmpty {
            guard chunk.count <= maxBytes - payload.count else { throw CocoaError(.fileReadTooLarge) }
            payload.append(chunk)
        }
        return payload
    }
}
