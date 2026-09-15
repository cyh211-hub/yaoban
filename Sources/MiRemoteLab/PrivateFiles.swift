import Foundation
import Darwin

// Private, bounded files. Never follow a final symlink or operate on a shared inode.
enum PrivateFiles {
    static let settingsLimit = 1_048_576
    static func error(_ text: String) -> Error {
        NSError(domain: "PrivateFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static func checked(_ fd: Int32, directory: Bool = false) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { throw error("文件类型或归属不安全，未读取或修改。") }
        return info
    }
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw error("无法安全打开设置目录。") }
        defer { close(fd) }
        _ = try checked(fd, directory: true)
        guard fchmod(fd, 0o700) == 0 else { throw error("无法收紧设置目录权限。") }
    }
    static func read(_ url: URL, limit: Int = settingsLimit) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw error("无法安全读取「\(url.lastPathComponent)」。") }
        defer { close(fd) }
        let info = try checked(fd)
        guard limit >= 0, info.st_size >= 0, info.st_size <= limit else { throw error("文件过大，已拒绝读取。") }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit - result.count + 1))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw error("读取文件失败。") }
            if count == 0 { return result }
            guard count <= limit - result.count else { throw error("文件读取期间超过大小限制。") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    static func write(_ data: Data, to url: URL, limit: Int = settingsLimit) throws {
        guard data.count <= limit else { throw error("保存内容超过大小限制。") }
        let parent = url.deletingLastPathComponent()
        try ensureDirectory(parent)
        let dir = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { throw error("无法安全打开保存目录。") }
        defer { close(dir) }
        _ = try checked(dir, directory: true)
        var existing = stat()
        if fstatat(dir, url.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFREG,
                  existing.st_nlink == 1 else { throw error("目标不是本用户的独立普通文件，未覆盖。") }
        } else if errno != ENOENT { throw error("无法检查保存目标。") }
        let temporary = ".private-\(UUID().uuidString)"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error("无法创建私有临时文件。") }
        defer { close(fd); unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw error("文件写入失败。") }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(dir, temporary, dir, url.lastPathComponent) == 0 else {
            throw error("文件保存失败，原文件保留。")
        }
        _ = fsync(dir)
    }
    static func protectFile(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw error("无法安全设置文件权限。") }
        defer { close(fd) }
        _ = try checked(fd)
        guard fchmod(fd, 0o600) == 0 else { throw error("无法收紧文件权限。") }
    }
    static func protectTree(_ directory: URL) throws {
        try ensureDirectory(directory)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try protectTree(url)
            case S_IFREG: try protectFile(url)
            default: throw error("设置目录含链接或特殊文件，已停止启用。")
            }
        }
    }
}
