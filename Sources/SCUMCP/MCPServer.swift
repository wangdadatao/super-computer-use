import Foundation
import SCUCore
import SCUWire

/// MCP stdio 服务（接入层）：把 JSON-RPC 请求翻译成对 `DesktopReader` 的只读调用。
///
/// 接入层不持有状态、不含平台判断，可整体替换（system_overview.md）。
/// **不直接读写 stdin/stdout**：输入输出以闭包注入，便于测试，
/// 也保证 stdout 只有协议消息——任何日志都必须走 stderr。
///
/// 传输：每行一条 JSON 消息，换行分隔；消息内不含换行（`JSONValue.encodedLine` 保证）。
/// 不支持 JSON-RPC 批处理（2025-06-18 规范已移除）。
// @project-doc docs/interfaces/mcp_surface.md#jsonrpc_handling
public final class MCPServer {
    /// 按新到旧排列。客户端请求的版本在列表内则原样回显，否则回复第一项（规范的协商规则）。
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let reader: DesktopReader
    private let serverVersion: String

    public init(reader: DesktopReader, serverVersion: String) {
        self.reader = reader
        self.serverVersion = serverVersion
    }

    /// 读到 EOF 返回。`write` 返回 false 表示输出端已断开，同样结束。
    public func run(readLine: () -> String?, write: (String) -> Bool) {
        while let line = readLine() {
            guard let reply = handle(line: line) else { continue }
            if !write(reply) { return }
        }
    }

    // MARK: - 分发

    /// 处理一行输入，返回要写出的应答行；通知与空行返回 nil。
    public func handle(line: String) -> String? {
        if line.allSatisfy({ $0.isWhitespace }) { return nil }
        guard let message = JSONValue.parse(line) else {
            return error(id: .null, code: -32700, "无法解析为 JSON")
        }
        guard case .object = message else {
            return error(id: .null, code: -32600, "请求必须是 JSON 对象（不支持批处理）")
        }
        // 客户端发来的应答（含 result 或 error 且无 method）：本服务从不向客户端发请求，忽略。
        guard let method = message["method"]?.stringValue else {
            if message["result"] != nil || message["error"] != nil { return nil }
            return error(id: validID(message["id"]) ?? .null, code: -32600, "缺少 method")
        }

        // 没有 id 的是通知，不回复。
        guard let rawID = message["id"] else { return nil }
        guard let id = validID(rawID) else {
            return error(id: .null, code: -32600, "id 必须是字符串或整数")
        }
        let params = message["params"]

        switch method {
        case "initialize": return initialize(id: id, params: params)
        case "ping": return result(id: id, [:])
        case "tools/list": return result(id: id, ["tools": .array(ScuTool.allCases.map(\.definition))])
        case "tools/call": return callTool(id: id, params: params)
        default: return error(id: id, code: -32601, "不支持的方法：\(method)")
        }
    }

    private func validID(_ v: JSONValue?) -> JSONValue? {
        switch v {
        case .string?, .int?: return v
        default: return nil
        }
    }

    private func initialize(id: JSONValue, params: JSONValue?) -> String {
        guard let requested = params?["protocolVersion"]?.stringValue else {
            return error(id: id, code: -32602, "initialize 缺少 protocolVersion")
        }
        let version = Self.supportedProtocolVersions.contains(requested)
            ? requested : Self.supportedProtocolVersions[0]
        return result(id: id, [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "scu", "version": .string(serverVersion)],
            "instructions": .string(Self.instructions),
        ])
    }

    /// 给模型的整体使用说明。工具的细节在各自的 description 里。
    static let instructions = """
        SCU（SuperComputerUse）当前是只读档：只能读取 macOS 应用的无障碍树，不能点击、输入或改变任何东西。\
        典型流程：list_apps 取得 pid，再用 get_ax_state 读取元素表。\
        元素表里的句柄只在该次输出内有效。读取不到时先用 check_permissions 确认宿主应用的辅助功能权限。
        """

    private func callTool(id: JSONValue, params: JSONValue?) -> String {
        guard let name = params?["name"]?.stringValue else {
            return error(id: id, code: -32602, "tools/call 缺少 name")
        }
        guard let tool = ScuTool(rawValue: name) else {
            return error(id: id, code: -32602, "未知工具：\(name)")
        }
        let outcome = tool.run(arguments: params?["arguments"], reader: reader)
        return result(id: id, [
            "content": [["type": "text", "text": .string(outcome.text)]],
            "isError": .bool(outcome.isError),
        ])
    }

    // MARK: - 应答构造

    private func result(id: JSONValue, _ value: JSONValue) -> String {
        JSONValue.object(["jsonrpc": "2.0", "id": id, "result": value]).encodedLine()
    }

    private func error(id: JSONValue, code: Int, _ message: String) -> String {
        JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .int(code), "message": .string(message)],
        ]).encodedLine()
    }
}
