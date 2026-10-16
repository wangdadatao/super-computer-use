import Foundation
import SCUWire

/// 协议层到原生进程的连接：启动 sidecar、握手、同步请求/应答。
/// 动作在会话内串行，因此这里不需要并发请求（见 session_and_lease.md）。
///
/// 传输层的任何失败（对端关闭、写失败）都映射为 `platform_unavailable`，
/// 不让底层的 `TransportError` 泄漏给调用方。
// @project-doc docs/architecture/system_overview.md#process_boundary
public final class NativeClient {
    public enum ClientError: Error, CustomStringConvertible {
        case nativeExecutableNotFound(String)
        case connectTimeout
        case unexpectedResponse(String)

        public var description: String {
            switch self {
            case .nativeExecutableNotFound(let p): return "找不到原生进程可执行文件：\(p)"
            case .connectTimeout: return "等待原生进程就绪超时"
            case .unexpectedResponse(let s): return "原生进程返回了意料之外的应答：\(s)"
            }
        }
    }

    private let fd: Int32
    let process: Process
    private let socketDir: URL
    private var nextId = 1
    private var closed = false

    /// 启动 sidecar 并完成握手。握手失败（含版本不一致）时抛出 WireError。
    public init(
        nativeExecutable: URL,
        protocolVersion: Int = scuNativeProtocolVersion,
        nativeProtocolVersionOverride: Int? = nil
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: nativeExecutable.path) else {
            throw ClientError.nativeExecutableNotFound(nativeExecutable.path)
        }
        // 私有目录（0700）存放 socket，避免其他用户连入。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scu-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = dir.appendingPathComponent("n.sock").path

        let proc = Process()
        proc.executableURL = nativeExecutable
        var args = ["--socket", path]
        if let v = nativeProtocolVersionOverride { args += ["--protocol-version", String(v)] }
        proc.arguments = args
        do {
            try proc.run()
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }

        var connected: Int32?
        for _ in 0..<60 {
            if let c = try? UnixSocket.connect(to: path) {
                connected = c
                break
            }
            if !proc.isRunning { break }  // sidecar 已退出，不必等满
            usleep(50_000)
        }
        guard let fd = connected else {
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
            try? FileManager.default.removeItem(at: dir)
            throw ClientError.connectTimeout
        }
        self.fd = fd
        self.process = proc
        self.socketDir = dir

        do {
            let reply = try call(.hello(protocolVersion: protocolVersion))
            guard case .hello(let serverVersion) = reply, serverVersion == protocolVersion else {
                throw ClientError.unexpectedResponse("\(reply)")
            }
        } catch {
            close()
            throw error
        }
    }

    /// 发送一条请求并等待应答。`.failure` 以 WireError 抛出，调用方按 code 分支。
    ///
    /// `timeoutMs`：等待应答的上限。超时意味着原生进程无响应；此时连接已无法再对齐帧边界，
    /// 本连接被关闭（并终止原生进程），以 `platform_unavailable` 失败。
    @discardableResult
    public func call(_ request: Request, timeoutMs: Int32 = 30_000) throws -> Response {
        let id = nextId
        nextId += 1
        let frame: ResponseFrame
        do {
            try Frame.write(RequestFrame(id: id, request: request), to: fd)
            try UnixSocket.waitReadable(fd, timeoutMs: timeoutMs)
            frame = try Frame.read(ResponseFrame.self, from: fd)
        } catch let e as TransportError {
            switch e {
            case .timeout:
                close()
                throw WireError.platformUnavailable("原生进程在 \(timeoutMs) 毫秒内无应答，已终止")
            case .closed:
                // 握手阶段版本错配时，原生层会先回错误帧再关闭；写后读到的是错误帧而不是 EOF，
                // 因此走到这里意味着对端在未应答的情况下消失了。
                throw WireError.platformUnavailable("原生进程已断开")
            default:
                throw WireError.platformUnavailable("与原生进程通信失败：\(e)")
            }
        }
        guard frame.id == id else { throw ClientError.unexpectedResponse("应答 id \(frame.id) ≠ \(id)") }
        if case .failure(let e) = frame.response { throw e }
        return frame.response
    }

    /// 幂等：可重复调用。
    public func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: socketDir)
    }

    deinit {
        close()
    }
}
