import Foundation

/// 单帧上限。防止对端发来畸形长度导致巨量分配。
public let scuMaxFrameBytes = 64 * 1024 * 1024

public enum TransportError: Error, Equatable {
    case pathTooLong
    case socket(String)
    case frameTooLarge(Int)
    /// 对端已关闭（读到 EOF，或写时遇到 EPIPE / ECONNRESET）。
    case closed
    case timeout
}

/// 长度前缀 JSON 帧：4 字节大端长度 + UTF-8 JSON。
// @project-doc docs/interfaces/native_wire_protocol.md#frame_format
public enum Frame {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= scuMaxFrameBytes else { throw TransportError.frameTooLarge(body.count) }
        var out = Data()
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    public static func decode<T: Decodable>(_ type: T.Type, body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    public static func write<T: Encodable>(_ value: T, to fd: Int32) throws {
        let data = try encode(value)
        try writeAll(fd, data)
    }

    public static func read<T: Decodable>(_ type: T.Type, from fd: Int32) throws -> T {
        let header = try readExactly(fd, 4)
        let len = header.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard len <= scuMaxFrameBytes else { throw TransportError.frameTooLarge(len) }
        let body = try readExactly(fd, len)
        return try decode(type, body: body)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    // 对端已关闭：报告为 closed，由调用方映射为 platform_unavailable。
                    if errno == EPIPE || errno == ECONNRESET { throw TransportError.closed }
                    throw TransportError.socket("write: \(String(cString: strerror(errno)))")
                }
                offset += n
            }
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == ECONNRESET { throw TransportError.closed }
                throw TransportError.socket("read: \(String(cString: strerror(errno)))")
            }
            if n == 0 { throw TransportError.closed }
            offset += n
        }
        return Data(buf)
    }
}

/// Unix domain socket 的最小封装。
public enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString).map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw TransportError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// 对端关闭后继续写会让进程收到 SIGPIPE 而直接死亡，连错误都来不及抛出。
    /// 在 fd 上设置 SO_NOSIGPIPE，使写失败退化为 EPIPE 错误。
    /// 所有经本类型创建的 fd 都会设置；自行创建 fd（如 socketpair）的调用方需要手动调用。
    public static func suppressSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 绑定并监听。调用方负责保证 path 所在目录是私有的。
    public static func listen(at path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socket("socket: \(String(cString: strerror(errno)))") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 1) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw TransportError.socket("bind/listen: \(msg)")
        }
        return fd
    }

    /// 接受一条连接。`timeoutMs` 内无连接则抛 `.timeout`，避免客户端先于连接死亡时 sidecar 永久阻塞。
    public static func accept(_ listenFd: Int32, timeoutMs: Int32) throws -> Int32 {
        var pfd = pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0)
        while true {
            let rc = poll(&pfd, 1, timeoutMs)
            if rc < 0 {
                if errno == EINTR { continue }
                throw TransportError.socket("poll: \(String(cString: strerror(errno)))")
            }
            if rc == 0 { throw TransportError.timeout }
            break
        }
        while true {
            let fd = Darwin.accept(listenFd, nil, nil)
            if fd >= 0 {
                suppressSigPipe(fd)
                return fd
            }
            if errno == EINTR { continue }
            throw TransportError.socket("accept: \(String(cString: strerror(errno)))")
        }
    }

    public static func connect(to path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TransportError.socket("socket: \(String(cString: strerror(errno)))") }
        suppressSigPipe(fd)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw TransportError.socket("connect: \(msg)")
        }
        return fd
    }
}
