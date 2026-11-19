import Darwin
import Foundation

enum ClaudeUsageClient {
    enum Failure: LocalizedError {
        case notInstalled, unsupported, accountUnavailable, unavailable, timedOut, invalidResponse

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Install Claude Code and sign in with your Claude subscription to check limits."
            case .unsupported:
                return "Update Claude Code to enable automatic subscription limit checks."
            case .accountUnavailable:
                return "Claude Code didn’t report subscription limits. Check the signed-in account and plan."
            case .unavailable:
                return "Claude couldn’t return your current limits. Refresh to try again."
            case .timedOut:
                return "The Claude usage check timed out. QuotaBar will try again."
            case .invalidResponse:
                return "Claude returned an unrecognized usage reading. Update Claude Code and try again."
            }
        }
    }

    static func read(executable: URL? = nil, timeout: TimeInterval = 15) throws -> QuotaReading {
        guard let executable = executable ?? executableURL() else { throw Failure.notInstalled }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "quotabar-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        process.executableURL = executable
        process.arguments = [
            "-p", "--safe-mode", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--strict-mcp-config", "--tools", "", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}",
        ]
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { throw Failure.unavailable }
        let writer = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        defer {
            try? writer.close()
            if exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut, process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + .milliseconds(250))
                }
            }
            try? reader.close()
        }
        for descriptor in [writer.fileDescriptor, reader.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw Failure.unavailable }
        }
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else { throw Failure.unavailable }
        var transport = Transport(
            reader: reader, writer: writer, deadline: ProcessInfo.processInfo.systemUptime + max(0, timeout))
        // Control requests do not enter the conversation or trigger a model response.
        _ = try transport.request(id: "initialize", request: ["subtype": "initialize"])
        let data = try transport.request(id: "usage", request: ["subtype": "get_usage", "skip_behaviors": true])
        return try parse(data, now: Date())
    }

    static func parse(_ data: Data, now: Date) throws -> QuotaReading {
        let report: Report
        do { report = try JSONDecoder().decode(Report.self, from: data) } catch { throw Failure.invalidResponse }
        guard report.rateLimitsAvailable else { throw Failure.accountUnavailable }
        guard let limits = report.rateLimits else { throw Failure.unavailable }
        var windows: [QuotaWindow] = []
        for (minutes, window) in [(300, limits.fiveHour), (10_080, limits.sevenDay)] {
            guard let window else { continue }
            guard let used = window.utilization, used.isFinite, (0...100).contains(used),
                let timestamp = window.resetsAt, let reset = isoDate(timestamp)
            else { throw Failure.invalidResponse }
            guard reset > now else { continue }
            windows.append(QuotaWindow(minutes: minutes, used: used, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw Failure.unavailable }
        return QuotaReading(fetchedAt: now, windows: windows)
    }

    private static func isoDate(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    private struct Report: Decodable {
        let rateLimitsAvailable: Bool
        let rateLimits: Limits?
        enum CodingKeys: String, CodingKey {
            case rateLimitsAvailable = "rate_limits_available"
            case rateLimits = "rate_limits"
        }
    }

    private struct Limits: Decodable {
        let fiveHour: Window?
        let sevenDay: Window?
        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
        }
    }

    private struct Window: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private static func executableURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources/claude"),
        ]
        let custom = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        return (candidates + custom).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private struct Transport {
        let reader: FileHandle
        let writer: FileHandle
        let deadline: TimeInterval
        private var buffer = Data()
        private var receivedBytes = 0
        private let maximumBytes = 2 * 1024 * 1024

        init(reader: FileHandle, writer: FileHandle, deadline: TimeInterval) {
            self.reader = reader
            self.writer = writer
            self.deadline = deadline
        }

        mutating func request(id: String, request: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "control_request", "request_id": id, "request": request,
            ])
            data.append(0x0A)
            try wait(writer.fileDescriptor, for: Int16(POLLOUT))
            do { try writer.write(contentsOf: data) } catch { throw Failure.unavailable }
            while true {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw Failure.invalidResponse
                    }
                    guard message["type"] as? String == "control_response",
                        let response = message["response"] as? [String: Any],
                        response["request_id"] as? String == id
                    else { continue }
                    if response["subtype"] as? String == "error" {
                        let error = (response["error"] as? String ?? "").lowercased()
                        if error.contains("unknown control")
                            || (error.contains("get_usage")
                                && (error.contains("not supported") || error.contains("unknown")
                                    || error.contains("unsupported")))
                        {
                            throw Failure.unsupported
                        }
                        throw Failure.unavailable
                    }
                    guard response["subtype"] as? String == "success" else { throw Failure.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: response["response"] as? [String: Any] ?? [:])
                }
                try wait(reader.fileDescriptor, for: Int16(POLLIN))
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(reader.fileDescriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw Failure.unavailable }
                let chunk = Data(bytes.prefix(count))
                receivedBytes += chunk.count
                guard receivedBytes <= maximumBytes else { throw Failure.invalidResponse }
                buffer.append(chunk)
            }
        }

        private func wait(_ descriptor: Int32, for event: Int16) throws {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw Failure.timedOut }
                var pollDescriptor = pollfd(fd: descriptor, events: event, revents: 0)
                let result = poll(&pollDescriptor, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Failure.unavailable
                }
                if result > 0 {
                    guard pollDescriptor.revents & (event | Int16(POLLHUP)) != 0 else { throw Failure.unavailable }
                    return
                }
            }
        }
    }
}
