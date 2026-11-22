import Darwin
import Foundation

@main
struct ClaudeDisconnect {
    static func main() {
        guard CommandLine.arguments.count == 1, let executable = Bundle.main.executableURL,
            executable.deletingLastPathComponent().lastPathComponent == ".quotabar"
        else {
            FileHandle.standardError.write(Data("Run uninstall.sh from the connected Claude profile.\n".utf8))
            exit(EXIT_FAILURE)
        }
        let root = executable.deletingLastPathComponent()
        do {
            try ClaudeConnection.disconnect(directory: root.deletingLastPathComponent())
            print("Disconnected the Claude status line.")
            if FileManager.default.fileExists(atPath: root.path) { print("Kept other files in " + root.path + ".") }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }
}
