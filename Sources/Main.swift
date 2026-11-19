import AppKit

@main
enum QuotaBar {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--capture-claude-quota"]) {
            guard ProviderSelection.saved(in: .standard) != .codex else { return }
            let payload: Data
            do {
                payload = try readStatusLine()
            } catch {
                try? ClaudeQuotaSource.invalidate()
                exit(1)
            }
            do {
                try ClaudeQuotaSource.capture(statusLine: payload)
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
