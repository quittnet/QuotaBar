import CryptoKit
import Darwin
import Foundation
import Security

/// Automatic discovery accepts the provider's signed CLI. Other installations require an explicit file choice.
enum ProviderExecutable {
    private struct Selection: Codable {
        let path: String
        let target: String
        let digest: Data
    }

    private struct Revision: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init(_ path: String, _ info: stat) {
            self.path = path
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_ctimespec.tv_sec
            nanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private final class VerificationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [String: (revision: Revision, valid: Bool, time: TimeInterval)] = [:]
        func check(_ name: String, _ revision: Revision, verify: () -> Bool) -> Bool {
            let key = name + ":" + revision.path
            let now = ProcessInfo.processInfo.systemUptime
            if let prior = lock.withLock({ results[key] }), prior.revision == revision,
                prior.valid || now - prior.time < 60
            {
                return prior.valid
            }
            let valid = verify()
            lock.withLock {
                if results.count >= 128 { results.removeAll() }
                results[key] = (revision, valid, now)
            }
            return valid
        }
    }

    private static let cache = VerificationCache()
    private static func key(_ name: String) -> String { "chosenCLI." + name }

    static func hasSelection(_ name: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(name)) != nil
    }

    static func useAutomatic(_ name: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(name))
    }

    static func choose(_ url: URL, name: String, defaults: UserDefaults = .standard) throws {
        guard let (target, hash) = digest(url) else { throw CocoaError(.fileReadNoPermission) }
        let choice = Selection(path: url.path, target: target, digest: hash)
        defaults.set(try JSONEncoder().encode(choice), forKey: key(name))
    }

    static func selected(_ name: String, defaults: UserDefaults = .standard) -> URL? {
        guard let choice = selection(name, defaults) else { return nil }
        let target = URL(fileURLWithPath: choice.path).resolvingSymlinksInPath()
        if vendorSigned(target, name: name) { return target }
        guard target.path == choice.target, let revision = executableRevision(target) else { return nil }
        let valid = cache.check(choice.digest.base64EncodedString(), revision) {
            guard let (checked, hash) = digest(target) else { return false }
            return checked == choice.target && hash == choice.digest
        }
        return valid ? target : nil
    }

    static func installationDirectory(for target: URL, name: String, defaults: UserDefaults) -> URL? {
        guard let choice = selection(name, defaults) else { return nil }
        let alias = URL(fileURLWithPath: choice.path)
        guard alias.resolvingSymlinksInPath().path == target.path else { return nil }
        return alias.deletingLastPathComponent()
    }

    private static func selection(_ name: String, _ defaults: UserDefaults) -> Selection? {
        guard let data = defaults.data(forKey: key(name)) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }

    private static func executableRevision(_ target: URL) -> Revision? {
        var info = stat()
        guard lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            access(target.path, X_OK) == 0
        else { return nil }
        return Revision(target.path, info)
    }

    static func vendorSigned(_ url: URL, name: String) -> Bool {
        let target = url.resolvingSymlinksInPath()
        guard let revision = executableRevision(target) else { return false }
        return cache.check(name, revision) {
            let requirement: String
            switch name {
            case "codex":
                requirement =
                    #"anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2" and identifier "codex""#
            case "claude":
                requirement =
                    #"anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW" and identifier "com.anthropic.claude-code""#
            default: return false
            }
            var code: SecStaticCode?
            var rule: SecRequirement?
            let flags = SecCSFlags()
            guard SecStaticCodeCreateWithPath(target as CFURL, flags, &code) == errSecSuccess, let code,
                SecRequirementCreateWithString(requirement as CFString, flags, &rule) == errSecSuccess, let rule,
                SecStaticCodeCheckValidity(code, flags, rule) == errSecSuccess
            else { return false }
            var after = stat()
            return lstat(target.path, &after) == 0 && Revision(target.path, after) == revision
        }
    }

    private static func digest(_ url: URL) -> (String, Data)? {
        let target = url.resolvingSymlinksInPath()
        let fd = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
            access(target.path, X_OK) == 0
        else { return nil }
        let before = Revision(target.path, info)
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256()
        var remaining = info.st_size
        while remaining > 0 {
            guard
                let bytes = try? autoreleasepool(invoking: {
                    try stream.read(upToCount: Int(min(remaining, 256 * 1024)))
                }),
                !bytes.isEmpty
            else { return nil }
            hash.update(data: bytes)
            remaining -= Int64(bytes.count)
        }
        guard lstat(target.path, &info) == 0, before == Revision(target.path, info) else { return nil }
        return (target.path, Data(hash.finalize()))
    }
}
