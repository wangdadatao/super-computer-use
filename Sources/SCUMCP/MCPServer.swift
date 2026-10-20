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

    private let session: DesktopSession
    private let serverVersion: String
    private let actionsEnabled: Bool

    /// - Parameter actionsEnabled: 是否暴露会改变桌面状态的工具。**默认关闭**，由启动参数显式开启。
    public init(
        reader: DesktopReader, serverVersion: String, actionsEnabled: Bool = false,
        policy: PolicyGate = PolicyGate(), settle: DesktopSession.Settle = DesktopSession.Settle()
    ) {
        self.session = DesktopSession(reader: reader, policy: policy, settle: settle)
        self.serverVersion = serverVersion
        self.actionsEnabled = actionsEnabled
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
        case "tools/list": return result(id: id, ["tools": .array(ScuTool.available(actions: actionsEnabled).map(\.definition))])
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
            "instructions": .string(actionsEnabled ? Self.actionInstructions : Self.instructions),
        ])
    }

    /// 给模型的整体使用说明。工具的细节在各自的 description 里。
    static let instructions = """
        SCU（SuperComputerUse）当前是只读档：只能读取 macOS 应用的无障碍树，不能点击、输入或改变任何东西。\
        典型流程：list_apps 取得 pid，再用 get_ax_state 读取元素表；需要看界面时用 get_screenshot。\
        元素表里的标签/句柄与标题行的令牌配对，令牌失效后不可用。读取不到时先用 check_permissions 确认宿主应用的辅助功能权限；
        截图还需要屏幕录制权限，两者按宿主应用归属。
        """

    static let actionInstructions = """
        SCU（SuperComputerUse）动作档：可以读取 macOS 应用的无障碍树，用 click 点击元素，\
        用 type_text 逐字输入文本，用 press_key 发送按键或组合键，用 set_value 直接写值。\
        典型流程：list_apps 取得 pid，get_ax_state 读取元素表（标题行有令牌），再用 click / type_text / press_key / set_value（token 加 handle 或 label）。\
        需要看界面时用 get_screenshot（需要屏幕录制权限）；图上会叠加与元素表一致的 [a] 标签。\
        动作前会核对目标仍是读取时的那个，不是就拒绝并告诉你原因；点击后会报告观察到的效果，\
        结构变化时令牌作废需重读，"疑似空操作"需要你核实。终端、脚本运行器、密码管理器、系统设置、Cursor 等属于拒绝类目，\
        拒绝不可协商，请让用户自己完成。读取不到时先用 check_permissions 确认宿主应用的辅助功能权限。
        """

    private func callTool(id: JSONValue, params: JSONValue?) -> String {
        guard let name = params?["name"]?.stringValue else {
            return error(id: id, code: -32602, "tools/call 缺少 name")
        }
        guard let tool = ScuTool(rawValue: name), actionsEnabled || !tool.isAction else {
            return error(id: id, code: -32602, "未知工具：\(name)")
        }
        let outcome = tool.run(arguments: params?["arguments"], session: session, actionsEnabled: actionsEnabled)
        var content: [JSONValue] = [
            .object(["type": .string("text"), "text": .string(outcome.text)])
        ]
        for image in outcome.images {
            content.append(.object([
                "type": .string("image"),
                "data": .string(image.data.base64EncodedString()),
                "mimeType": .string(image.mimeType),
            ]))
        }
        return result(id: id, [
            "content": .array(content),
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
