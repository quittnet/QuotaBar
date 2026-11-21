import Darwin
import Foundation

/// JSONSerialization validates the document. These ranges let us edit only the selected
/// member while leaving the user's ordering, whitespace, escaping and numeric literals intact.
struct ClaudeSettingsDocument {
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? {
            "QuotaBar couldn’t safely edit settings.json. Use an unambiguous UTF-8 JSON object for Claude Code settings."
        }
    }

    private struct Member {
        let name: String
        let start: Int
        let value: Range<Int>
        let comma: Int?
    }

    let data: Data
    let object: [String: Any]
    private let bytes: [UInt8]
    private let rootStart: Int

    init(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unsupported
        }
        self.data = data
        self.object = object
        bytes = Array(data)
        let beginning = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? 3 : 0
        guard let start = bytes[beginning...].firstIndex(where: { !Self.whitespace.contains($0) }), bytes[start] == 123
        else { throw Failure.unsupported }
        rootStart = start
    }

    static let empty = Data("{}\n".utf8)
    private static let whitespace: Set<UInt8> = [9, 10, 13, 32]

    private func skipSpace(_ index: Int) -> Int {
        var i = index
        while i < bytes.count, Self.whitespace.contains(bytes[i]) { i += 1 }
        return i
    }

    private func endOfString(_ start: Int) throws -> Int {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == 34 { return i + 1 }
            i += bytes[i] == 92 ? 2 : 1
        }
        throw Failure.unsupported
    }

    private func endOfValue(_ start: Int) throws -> Int {
        var i = start
        var depth = 0
        while i < bytes.count {
            switch bytes[i] {
            case 34:
                i = try endOfString(i)
                if depth == 0 { return i }
                continue
            case 123, 91: depth += 1
            case 125, 93:
                if depth == 0 { return i }
                depth -= 1
                if depth == 0 { return i + 1 }
            case 44, 9, 10, 13, 32:
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        throw Failure.unsupported
    }

    private func members(at start: Int) throws -> [Member] {
        var i = skipSpace(start + 1)
        var members: [Member] = []
        while i < bytes.count, bytes[i] != 125 {
            guard bytes[i] == 34 else { throw Failure.unsupported }
            let nameEnd = try endOfString(i)
            let name = try JSONDecoder().decode(String.self, from: Data(bytes[i..<nameEnd]))
            let colon = skipSpace(nameEnd)
            guard colon < bytes.count, bytes[colon] == 58 else { throw Failure.unsupported }
            let value = skipSpace(colon + 1)
            let end = try endOfValue(value)
            let separator = skipSpace(end)
            guard separator < bytes.count else { throw Failure.unsupported }
            let comma = bytes[separator] == 44 ? separator : nil
            members.append(Member(name: name, start: i, value: value..<end, comma: comma))
            i = comma.map { skipSpace($0 + 1) } ?? separator
        }
        return members
    }

    private func member(_ name: String, in members: [Member]) throws -> Member? {
        let matches = members.filter { $0.name == name }
        guard matches.count <= 1 else { throw Failure.unsupported }
        return matches.first
    }

    private func replacing(_ range: Range<Int>, with replacement: Data) -> Data {
        var updated = data
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    private func statusLine() throws -> Member? {
        try member("statusLine", in: members(at: rootStart))
    }

    func rawStatusLine() throws -> Data? {
        try statusLine().map { data.subdata(in: $0.value) }
    }

    func settingCommand(_ command: String) throws -> Data {
        let encoded = try JSONSerialization.data(
            withJSONObject: command, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return try settingCommand(raw: encoded)
    }

    private func commandField() throws -> Member? {
        guard let line = try statusLine(), bytes[line.value.lowerBound] == 123 else { return nil }
        guard let field = try member("command", in: members(at: line.value.lowerBound)) else {
            throw Failure.unsupported
        }
        return field
    }

    func rawCommand() throws -> Data? {
        try commandField().map { data.subdata(in: $0.value) }
    }

    func settingCommand(raw encoded: Data) throws -> Data {
        if let field = try commandField() { return replacing(field.value, with: encoded) }
        return try settingStatusLine(Data(#"{"type":"command","command":"#.utf8) + encoded + Data("}".utf8))
    }

    func settingStatusLine(_ raw: Data?) throws -> Data {
        let fields = try members(at: rootStart)
        if let line = try member("statusLine", in: fields) {
            if let raw { return replacing(line.value, with: raw) }
            if let comma = line.comma { return replacing(line.start..<(comma + 1), with: Data()) }
            let start = fields.dropLast().last?.comma ?? line.start
            return replacing(start..<line.value.upperBound, with: Data())
        }
        guard let raw else { return data }
        let end = fields.last?.value.upperBound ?? (rootStart + 1)
        let spacing = fields.first.map { Data(bytes[(rootStart + 1)..<$0.start]) } ?? Data()
        let inserted = (fields.isEmpty ? Data() : Data(",".utf8)) + spacing + Data(#""statusLine":"#.utf8) + raw
        return replacing(end..<end, with: inserted)
    }
}

/// Exchange the actual directory entries first, then validate the displaced file. This also
/// covers an editor's atomic save in the interval immediately before QuotaBar's rename.
enum ClaudeSettingsCommit {
    enum Stage { case beforeDisplacing, afterDisplacing, cleanup }
    typealias Observer = (Stage) throws -> Void

    private struct Conflict: LocalizedError {
        let saved: URL?
        var errorDescription: String? {
            if let saved {
                return
                    "Claude settings changed during this operation. Review the active settings and the saved version at "
                    + saved.path
            }
            return "Claude settings changed during this operation. Review the current settings and try again."
        }
    }

    static func apply(_ proposed: Data?, replacing expected: Data?, at url: URL, observe: Observer?) throws {
        let folder = url.deletingLastPathComponent().appendingPathComponent(
            ".quotabar-settings-recovery-" + UUID().uuidString)
        guard mkdir(folder.path, 0o700) == 0 else { throw posix() }
        let staged = folder.appendingPathComponent("settings.json")
        var removeStaged = true
        defer {
            if removeStaged { _ = unlink(staged.path) }
            _ = rmdir(folder.path)
        }
        var source = stat()
        let proposal = try proposed.map {
            try prepare($0, at: staged, metadataFrom: expected == nil ? nil : url, source: &source)
        }
        if proposed == nil {
            guard lstat(url.path, &source) == 0, (source.st_mode & S_IFMT) == S_IFREG, source.st_nlink == 1 else {
                throw Conflict(saved: nil)
            }
        }
        try observe?(.beforeDisplacing)
        guard let expected else {
            guard renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) == 0 else { throw posix() }
            return
        }
        let status =
            proposed == nil
            ? renamex_np(url.path, staged.path, UInt32(RENAME_EXCL))
            : renamex_np(staged.path, url.path, UInt32(RENAME_SWAP))
        guard status == 0 else { throw posix() }
        // From here, staged may be the only copy of an independent editor's work.
        removeStaged = false
        try observe?(.afterDisplacing)
        if matches(staged, bytes: expected, identity: source) {
            removeStaged = true
            return
        }
        if let proposed, let proposal {
            if matches(url, bytes: proposed, identity: proposal),
                renamex_np(staged.path, url.path, UInt32(RENAME_SWAP)) == 0
            {
                // An additional save can also race the rollback. Never unlink its contents.
                removeStaged = matches(staged, bytes: proposed, identity: proposal)
            }
        } else if renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) == 0 {
            removeStaged = true
        }
        throw Conflict(saved: removeStaged ? nil : staged)
    }

    private static func prepare(_ bytes: Data, at staged: URL, metadataFrom url: URL?, source: inout stat) throws
        -> stat
    {
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posix() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: bytes)
        if let url {
            let old = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard old >= 0 else { throw posix() }
            defer { close(old) }
            guard fstat(old, &source) == 0, (source.st_mode & S_IFMT) == S_IFREG, source.st_nlink == 1 else {
                throw Conflict(saved: nil)
            }
            guard fcopyfile(old, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw posix() }
        }
        var info = stat()
        guard fsync(fd) == 0, fstat(fd, &info) == 0 else { throw posix() }
        if url != nil, info.st_uid != source.st_uid || info.st_gid != source.st_gid || info.st_mode != source.st_mode {
            throw CocoaError(.fileWriteNoPermission)
        }
        return info
    }

    private static func matches(_ url: URL, bytes: Data, identity: stat) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_dev == identity.st_dev && info.st_ino == identity.st_ino
            && info.st_nlink == 1 && info.st_mode == identity.st_mode && info.st_uid == identity.st_uid
            && info.st_gid == identity.st_gid && info.st_flags == identity.st_flags
            && info.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec
            && info.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec
            && (try? PrivateFile.read(url, maximumBytes: bytes.count)) == bytes
    }

    private static func posix() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}
