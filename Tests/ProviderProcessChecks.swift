import Darwin
import Foundation

@main
struct ProviderProcessChecks {
    static func main() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("provider-children-" + UUID().uuidString)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: directory) }
        let independent = Process()
        independent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        independent.arguments = ["20"]
        try independent.run()
        defer {
            if independent.isRunning { independent.terminate() }
            independent.waitUntilExit()
        }
        for provider in ["codex", "claude"] {
            for scenario in ["wait", "early exit", "invalid reply"] {
                let wrapper = directory.appendingPathComponent(provider)
                let record = directory.appendingPathComponent("pid")
                let quoted = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
                let ending: String
                switch scenario {
                case "wait": ending = "wait"
                case "early exit": ending = "exit 0"
                default: ending = "printf 'invalid response\\n'; exit 0"
                }
                let source =
                    "#!/bin/sh\ntrap '' TERM\n/bin/sleep 6 &\nprintf '%s' \"$!\" > " + quoted + "\n" + ending + "\n"
                try Data(source.utf8).write(to: wrapper)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
                let started = DispatchTime.now()
                do {
                    if provider == "codex" {
                        _ = try QuotaSource.read(executable: wrapper, timeout: .milliseconds(250))
                    } else {
                        _ = try ClaudeUsageClient.read(executable: wrapper, timeout: 0.25)
                    }
                    preconditionFailure("Expected an unsuccessful fixture read")
                } catch {}
                guard let child = pid_t(try String(contentsOf: record, encoding: .utf8)), child > 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let deadline = DispatchTime.now() + .milliseconds(500)
                while kill(child, 0) == 0 && DispatchTime.now() < deadline { usleep(10_000) }
                precondition(kill(child, 0) < 0 && errno == ESRCH, "\(provider) left its worker after \(scenario)")
                precondition(DispatchTime.now() < started + .seconds(3), "Cleanup must stay bounded")
                precondition(independent.isRunning, "Cleanup reached another process group")
                try files.removeItem(at: record)
            }
        }
        print("Both provider readers cleaned up waiting and exited wrappers' finite workers after failed reads.")
    }
}
