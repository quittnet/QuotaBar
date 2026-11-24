import Darwin
import Foundation
import SQLite3

enum PrivateFile {
    static func databaseNeedsReopening(_ database: OpaquePointer) -> Bool {
        var moved: Int32 = 0
        let status = sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
        // Apple's SQLite can report a vnode I/O error when the open file has been unlinked or replaced.
        return status == SQLITE_OK ? moved != 0 : (status & 0xff) == SQLITE_IOERR
    }

    static func databasePath(_ url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o022 == 0
        else { throw CocoaError(.fileWriteNoPermission) }

        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
            // Publish a closed 0600 file. Closing a second descriptor for an active SQLite
            // database can drop all POSIX locks this process holds on its inode.
            let temporary = directory.appendingPathComponent(".quotabar-db-" + UUID().uuidString)
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            close(fd)
            defer { unlink(temporary.path) }
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0
        else { throw CocoaError(.fileWriteNoPermission) }
        // macOS exposes its user temporary directory through /var -> /private/var.
        // Resolve the validated directory while leaving SQLite's no-follow check on the file itself.
        guard let resolved = realpath(directory.path, nil) else { throw CocoaError(.fileWriteNoPermission) }
        defer { free(resolved) }
        return String(cString: resolved) + "/" + url.lastPathComponent
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size >= 0, info.st_size <= maximumBytes,
            let data = try handle.read(upToCount: Int(info.st_size) + 1), data.count == info.st_size
        else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
