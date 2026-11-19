import Darwin
import Foundation

enum PrivateFile {
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
