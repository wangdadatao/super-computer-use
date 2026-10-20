import Foundation
import SCUWire

/// 原生进程的服务循环：接受一条连接，握手后逐帧应答，对端关闭即退出。
/// sidecar 的生命周期绑定到连接——不做常驻（生命周期策略是系统总览里的未定项）。
public struct NativeServer: Sendable {
    public let socketPath: String
    public var protocolVersion: Int
    /// 等待协议层连入的上限。协议层在连接前死亡时，sidecar 据此自行退出而不是成为孤儿。
    public var acceptTimeoutMs: Int32

    public init(
        socketPath: String, protocolVersion: Int = scuNativeProtocolVersion, acceptTimeoutMs: Int32 = 10_000
    ) {
        self.socketPath = socketPath
        self.protocolVersion = protocolVersion
        self.acceptTimeoutMs = acceptTimeoutMs
    }

    // @project-doc docs/decisions/adr_0012_protocol_versioning.md#internal_boundary
    public func run() throws {
        let listenFd = try UnixSocket.listen(at: socketPath)
        defer {
            close(listenFd)
            unlink(socketPath)
        }
        let fd = try UnixSocket.accept(listenFd, timeoutMs: acceptTimeoutMs)
        defer { close(fd) }

        var handshaken = false
        while true {
            let frame: RequestFrame
            do {
                frame = try Frame.read(RequestFrame.self, from: fd)
            } catch TransportError.closed {
                return  // 对端关闭（含半帧到达后关闭）：正常退出
            } catch TransportError.frameTooLarge(let n) {
                // 超长帧的主体不会被读取，无法再对齐帧边界：应答后关闭连接。
                try? reply(fd, id: 0, .failure(.internalError("帧过大：\(n) 字节，上限 \(scuMaxFrameBytes)")))
                return
            } catch is DecodingError {
                try? reply(fd, id: 0, .failure(.internalError("无法解析请求")))
                return
            }

            if !handshaken {
                // 握手之前只接受 hello；版本不一致明确拒绝并关闭，不降级运行（ADR-0012）。
                guard case .hello(let clientVersion) = frame.request else {
                    try? reply(fd, id: frame.id, .failure(.internalError("必须先完成握手")))
                    return
                }
                guard clientVersion == protocolVersion else {
                    try? reply(
                        fd, id: frame.id,
                        .failure(.versionMismatch(client: clientVersion, server: protocolVersion)))
                    return
                }
                handshaken = true
                try reply(fd, id: frame.id, .hello(protocolVersion: protocolVersion))
            } else {
                try reply(fd, id: frame.id, handle(frame.request))
            }
        }
    }

    func reply(_ fd: Int32, id: Int, _ response: Response) throws {
        try Frame.write(ResponseFrame(id: id, response: response), to: fd)
    }

    func handle(_ request: Request) -> Response {
        switch request {
        case .hello:
            return .failure(.internalError("重复握手"))
        case .checkPermissions:
            return .permissions(accessibility: AXBackend.isAccessibilityTrusted())
        case .listApps:
            return .apps(AXBackend.listApps())
        case .dumpTree(let pid, let maxDepth, let budgetMs):
            guard (0...scuMaxTreeDepth).contains(maxDepth) else {
                return .failure(.internalError("maxDepth 必须在 0...\(scuMaxTreeDepth)，收到 \(maxDepth)"))
            }
            guard scuTreeBudgetMsRange.contains(budgetMs) else {
                return .failure(.internalError("budgetMs 必须在 \(scuTreeBudgetMsRange)，收到 \(budgetMs)"))
            }
            do {
                let r = try AXBackend.dumpTree(pid: pid, maxDepth: maxDepth, budgetMs: budgetMs)
                return .tree(r.root, truncated: r.truncated)
            } catch let e as WireError {
                return .failure(e)
            } catch {
                return .failure(.internalError("\(error)"))
            }
        case .performAction(let pid, let locator, let action):
            if let problem = validate(locator) { return .failure(.internalError(problem)) }
            return actionResponse {
                try AXBackend.performAction(pid: pid, locator: locator, action: action)
            }
        case .typeText(let pid, let locator, let text):
            if let problem = validate(locator) { return .failure(.internalError(problem)) }
            return actionResponse {
                try AXBackend.typeText(pid: pid, locator: locator, text: text)
            }
        case .pressKey(let pid, let locator, let key):
            if let problem = validate(locator) { return .failure(.internalError(problem)) }
            return actionResponse {
                try AXBackend.pressKey(pid: pid, locator: locator, key: key)
            }
        case .setValue(let pid, let locator, let value):
            if let problem = validate(locator) { return .failure(.internalError(problem)) }
            return actionResponse {
                try AXBackend.setValue(pid: pid, locator: locator, value: value)
            }
        case .captureWindow(let pid):
            do {
                return .windowCapture(try ScreenCapture.captureWindow(pid: pid))
            } catch let e as WireError {
                return .failure(e)
            } catch {
                return .failure(.platformUnavailable("截图失败：\(error)"))
            }
        case .clickAt(let pid, let x, let y):
            do {
                try Mouse.clickAt(pid: pid, x: x, y: y)
                return .acted
            } catch let e as WireError {
                return .failure(e)
            } catch {
                return .failure(.actionFailed("坐标点击失败：\(error)"))
            }
        }

    /// 把动作结果或错误统一映射为应答，避免三类动作各写一遍。
    func actionResponse(_ body: () throws -> AXBackend.ActionResult) -> Response {
        do {
            switch try body() {
            case .acted: return .acted
            case .located: return .located
            case .stale(let detail): return .stale(detail)
            }
        } catch let e as WireError {
            return .failure(e)
        } catch {
            return .failure(.internalError("\(error)"))
        }
    }
    }

    /// 定位器的结构检查。深度上限与读树一致：路径不可能比能读到的树更深。
    func validate(_ locator: ElementLocator) -> String? {
        guard locator.path.count <= scuMaxTreeDepth else {
            return "路径过长：\(locator.path.count)，上限 \(scuMaxTreeDepth)"
        }
        for (i, step) in locator.path.enumerated() {
            guard step.siblings >= 1, (0..<step.siblings).contains(step.index) else {
                return "路径第 \(i) 步无效：index \(step.index)，siblings \(step.siblings)"
            }
        }
        return nil
    }
}
