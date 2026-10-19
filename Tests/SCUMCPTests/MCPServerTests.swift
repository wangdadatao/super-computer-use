import Foundation
import Testing

@testable import SCUCore
@testable import SCUMCP
@testable import SCUWire

/// 不拉起原生进程、不依赖本机权限的假读取器。
final class FakeReader: DesktopReader {
    var permissions: Result<Bool, WireError> = .success(true)
    var apps: Result<[AppInfo], WireError> = .success([AppInfo(pid: 42, name: "演示", bundleId: "com.example.demo")])
    var tree: Result<TreeReading, WireError> = .success(
        TreeReading(root: AXNode(role: "AXWindow", title: "主窗口"), truncated: false))
    private(set) var treeCalls: [(pid: Int32, depth: Int, budget: Int)] = []
    var action: Result<ActionOutcome, WireError> = .success(.acted)
    private(set) var actionCalls: [(pid: Int32, locator: ElementLocator, action: ActionKind)] = []
    private(set) var typed: [(pid: Int32, locator: ElementLocator, text: String)] = []
    private(set) var pressed: [(pid: Int32, locator: ElementLocator, key: String)] = []

    func checkPermissions() throws -> Bool { try permissions.get() }
    func listApps() throws -> [AppInfo] { try apps.get() }
    func readTree(pid: Int32, maxDepth: Int, budgetMs: Int) throws -> TreeReading {
        treeCalls.append((pid, maxDepth, budgetMs))
        return try tree.get()
    }
    func performAction(pid: Int32, locator: ElementLocator, action kind: ActionKind) throws -> ActionOutcome {
        actionCalls.append((pid, locator, kind))
        return try action.get()
    }
    func typeText(pid: Int32, locator: ElementLocator, text: String) throws -> ActionOutcome {
        typed.append((pid, locator, text))
        return try action.get()
    }
    func pressKey(pid: Int32, locator: ElementLocator, key: String) throws -> ActionOutcome {
        pressed.append((pid, locator, key))
        return try action.get()
    }
}

/// 一次工具调用的解析结果。
struct ToolReply: Equatable {
    var text: String
    var isError: Bool
}

@Suite struct MCPServerTests {
    let reader = FakeReader()
    var server: MCPServer { MCPServer(reader: reader, serverVersion: "test") }

    func request(_ s: MCPServer, _ method: String, id: JSONValue = 1, params: JSONValue? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
        if let params { o["params"] = params }
        let reply = s.handle(line: JSONValue.object(o).encodedLine())
        return JSONValue.parse(reply ?? "") ?? .null
    }

    func callTool(_ s: MCPServer, _ name: String, _ args: JSONValue? = nil) -> ToolReply {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let args { params["arguments"] = args }
        let r = request(s, "tools/call", params: .object(params))
        let text = r["result"]?["content"]?.arrayFirst?["text"]?.stringValue ?? ""
        return ToolReply(text: text, isError: r["result"]?["isError"] == .bool(true))
    }

    // MARK: - 握手与目录

    @Test func initializeEchoesSupportedVersion() {
        let s = server
        for v in MCPServer.supportedProtocolVersions {
            let r = request(s, "initialize", params: ["protocolVersion": .string(v)])
            #expect(r["result"]?["protocolVersion"]?.stringValue == v)
        }
        let r = request(s, "initialize", params: ["protocolVersion": "1999-01-01"])
        #expect(r["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
        #expect(r["result"]?["serverInfo"]?["name"]?.stringValue == "scu")
        #expect(r["result"]?["capabilities"]?["tools"] != nil)
        #expect(r["result"]?["instructions"]?.stringValue?.contains("只读") == true)
    }

    @Test func initializeWithoutVersionIsInvalidParams() {
        let r = request(server, "initialize", params: [:])
        #expect(r["error"]?["code"] == .int(-32602))
    }

    @Test func toolsListIsReadOnlyAndComplete() {
        let r = request(server, "tools/list")
        guard case .array(let tools)? = r["result"]?["tools"] else { Issue.record("缺少 tools"); return }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == ["check_permissions", "list_apps", "get_ax_state"])
        for t in tools {
            // 只读档的核心承诺：没有任何工具会改变桌面状态。
            #expect(t["annotations"]?["readOnlyHint"] == .bool(true))
            #expect(t["annotations"]?["destructiveHint"] == .bool(false))
            #expect(t["inputSchema"]?["type"]?.stringValue == "object")
            #expect(t["description"]?.stringValue?.isEmpty == false)
        }
        let ax = tools.first { $0["name"]?.stringValue == "get_ax_state" }
        #expect(ax?["inputSchema"]?["required"] == ["pid"])
    }

    @Test func pingReturnsEmptyResult() {
        #expect(request(server, "ping")["result"] == [:])
    }

    // MARK: - JSON-RPC 边界

    @Test func notificationsAndBlankLinesGetNoReply() {
        let s = server
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"whatever/unknown"}"#) == nil)
        #expect(s.handle(line: "") == nil)
        #expect(s.handle(line: "   ") == nil)
    }

    @Test func clientResponsesAreIgnored() {
        #expect(server.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#) == nil)
    }

    @Test func unknownMethodWithIdIsMethodNotFound() {
        #expect(request(server, "resources/list")["error"]?["code"] == .int(-32601))
    }

    @Test func malformedInputGetsParseError() {
        let r = JSONValue.parse(server.handle(line: "{not json") ?? "")
        #expect(r?["error"]?["code"] == .int(-32700))
        #expect(r?["id"] == .null)
    }

    @Test func batchAndNonObjectAreInvalidRequest() {
        for line in ["[]", "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]", "42", "\"x\""] {
            let r = JSONValue.parse(server.handle(line: line) ?? "")
            #expect(r?["error"]?["code"] == .int(-32600), "输入：\(line)")
        }
    }

    @Test func missingMethodKeepsId() {
        let r = JSONValue.parse(server.handle(line: #"{"jsonrpc":"2.0","id":7}"#) ?? "")
        #expect(r?["error"]?["code"] == .int(-32600))
        #expect(r?["id"] == .int(7))
    }

    @Test func idTypesArePreservedAndNullIsRejected() {
        let s = server
        #expect(request(s, "ping", id: "abc")["id"] == "abc")
        #expect(request(s, "ping", id: 123)["id"] == .int(123))
        let r = JSONValue.parse(s.handle(line: #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#) ?? "")
        #expect(r?["error"]?["code"] == .int(-32600))
    }

    @Test func repliesAreSingleLine() {
        // 元素文本里的换行必须被转义，否则会破坏 stdio 的"一行一条消息"。
        reader.tree = .success(TreeReading(
            root: AXNode(role: "AXWindow", title: "第一行\n第二行\r\n第三行\t\"引号\"\\反斜杠"), truncated: false))
        let line = server.handle(line: JSONValue.object([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "get_ax_state", "arguments": ["pid": 42]],
        ]).encodedLine())
        #expect(line?.contains("\n") == false)
        #expect(line?.contains("\r") == false)
        #expect(JSONValue.parse(line ?? "") != nil)
    }

    @Test func runLoopStopsOnEOFAndOnBrokenOutput() {
        let s = server
        var input = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ][...]
        var out: [String] = []
        s.run(readLine: { input.popFirst() }, write: { out.append($0); return true })
        #expect(out.count == 2)  // 通知不产生输出

        var input2 = [
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
        ][...]
        var out2: [String] = []
        s.run(readLine: { input2.popFirst() }, write: { out2.append($0); return false })
        #expect(out2.count == 1)  // 输出端断开后立即结束，不再处理后续输入
    }

    // MARK: - tools/call

    @Test func unknownToolAndMissingNameAreProtocolErrors() {
        let s = server
        #expect(request(s, "tools/call", params: ["name": "click"])["error"]?["code"] == .int(-32602))
        #expect(request(s, "tools/call", params: [:])["error"]?["code"] == .int(-32602))
    }

    @Test func checkPermissionsReportsBothStates() {
        let s = server
        reader.permissions = .success(true)
        #expect(callTool(s, "check_permissions") == ToolReply(text: "辅助功能：已授予（针对启动本服务的宿主应用）", isError: false))
        reader.permissions = .success(false)
        let denied = callTool(s, "check_permissions")
        #expect(denied.text.contains("未授予"))
        #expect(denied.text.contains("宿主"))
        #expect(!denied.isError)  // 这是对状态的如实报告，不是工具失败
    }

    @Test func listAppsFormatsTabSeparatedLines() {
        reader.apps = .success([
            AppInfo(pid: 1, name: "访达", bundleId: "com.apple.finder"),
            AppInfo(pid: 2, name: "无标识", bundleId: nil),
        ])
        let r = callTool(server, "list_apps")
        #expect(r.text == "1\t访达\tcom.apple.finder\n2\t无标识\t-")
        #expect(!r.isError)
    }

    @Test func getAXStateRendersTableWithHeader() {
        reader.tree = .success(TreeReading(
            root: AXNode(role: "AXWindow", title: "主窗口", children: [
                AXNode(role: "AXButton", title: "确定"),
                AXNode(role: "AXTextField", value: "abc"),
            ]), truncated: false))
        let r = callTool(server, "get_ax_state", ["pid": 42])
        #expect(!r.isError)
        let lines = r.text.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("# pid=42 令牌 s"))
        #expect(lines[0].contains("没有工具接受句柄"))
        #expect(lines[0].contains("元素 3"))
        #expect(lines[1] == #"[AXWindow#1] "主窗口""#)
        #expect(lines[2] == #"  [AXButton#2] "确定""#)
        #expect(lines[3] == #"  [AXTextField#3] value="abc""#)
    }

    @Test func getAXStatePassesDefaultsAndOverrides() {
        let s = server
        _ = callTool(s, "get_ax_state", ["pid": 42])
        _ = callTool(s, "get_ax_state", ["pid": 43, "max_depth": 3, "budget_ms": 500])
        _ = callTool(s, "get_ax_state", ["pid": 44.0])  // 部分客户端把整数序列化成 44.0
        #expect(reader.treeCalls.count == 3)
        #expect(reader.treeCalls[0].pid == 42 && reader.treeCalls[0].depth == 12 && reader.treeCalls[0].budget == 15_000)
        #expect(reader.treeCalls[1].pid == 43 && reader.treeCalls[1].depth == 3 && reader.treeCalls[1].budget == 500)
        #expect(reader.treeCalls[2].pid == 44)
    }

    @Test func invalidArgumentsAreToolErrorsAndNeverReachTheReader() {
        let s = server
        let cases: [JSONValue?] = [
            nil, [:], ["pid": "42"], ["pid": 0], ["pid": -1], ["pid": 1.5],
            ["pid": 42, "max_depth": 999], ["pid": 42, "budget_ms": 5],
            ["pid": 42, "max_elements": 0], ["pid": 42, "max_depth": "3"],
            ["pid": 42, "pidd": 1],  // 拼错的参数不能被静默忽略
            "not an object",
        ]
        for c in cases {
            let r = callTool(s, "get_ax_state", c)
            #expect(r.isError, "参数：\(String(describing: c))")
            #expect(r.text.hasPrefix("[invalid_argument]"), "参数：\(String(describing: c))")
        }
        #expect(reader.treeCalls.isEmpty)
        // 无参数工具同样拒绝多余参数
        #expect(callTool(s, "list_apps", ["x": 1]).isError)
        #expect(callTool(s, "check_permissions", ["x": 1]).isError)
    }

    @Test func wireErrorsBecomeToolErrorsWithCode() {
        reader.tree = .failure(.permissionMissing("辅助功能"))
        let r = callTool(server, "get_ax_state", ["pid": 42])
        #expect(r.isError)
        #expect(r.text.hasPrefix("[system_permission_missing]"))
        #expect(r.text.contains("宿主"))

        reader.tree = .failure(.targetMissing(pid: 42))
        let r2 = callTool(server, "get_ax_state", ["pid": 42])
        #expect(r2.isError)
        #expect(r2.text.hasPrefix("[target_missing]"))
        #expect(!r2.text.contains("宿主"))  // 提示只针对权限错误
    }

    @Test func notesTruncationDepthAndElementCap() {
        // 预算耗尽
        reader.tree = .success(TreeReading(root: AXNode(role: "AXWindow"), truncated: true))
        #expect(callTool(server, "get_ax_state", ["pid": 1]).text.contains("已截断"))

        // 达到深度上限
        let deep = AXNode(role: "A", children: [AXNode(role: "B", children: [AXNode(role: "C")])])
        reader.tree = .success(TreeReading(root: deep, truncated: false))
        #expect(callTool(server, "get_ax_state", ["pid": 1, "max_depth": 2]).text.contains("深度上限"))
        #expect(!callTool(server, "get_ax_state", ["pid": 1, "max_depth": 5]).text.contains("深度上限"))

        // 元素数上限
        let wide = AXNode(role: "AXGroup", children: (0..<10).map { _ in AXNode(role: "AXButton") })
        reader.tree = .success(TreeReading(root: wide, truncated: false))
        let capped = callTool(server, "get_ax_state", ["pid": 1, "max_elements": 4]).text
        #expect(capped.contains("元素 11"))
        #expect(capped.contains("显示 4"))
        #expect(capped.contains("按层级优先"))
        #expect(capped.contains("(折叠 7)"))  // 根折叠了未显示的 7 个后代
        #expect(capped.split(separator: "\n").count == 1 + 4)
    }

    @Test func focusParametersSelectSubtreesAndEmptyStringMeansUnset() {
        reader.tree = .success(TreeReading(
            root: AXNode(role: "AXWindow", children: [
                AXNode(role: "AXButton", title: "确定"), AXNode(role: "AXButton", title: "取消"),
            ]), truncated: false))
        let s = server
        let one = callTool(s, "get_ax_state", ["pid": 1, "focus": "确定"])
        #expect(!one.isError)
        #expect(one.text.contains("focus 命中 1 处"))
        #expect(one.text.contains("@ AXWindow"))
        #expect(one.text.contains(#"[AXButton#2] "确定""#))
        #expect(!one.text.contains("取消"))

        let byRole = callTool(s, "get_ax_state", ["pid": 1, "focus_role": "Button"])
        #expect(byRole.text.contains("focus 命中 2 处"))

        // 模型常把不需要的可选参数填成空串：等价于没给。
        let empty = callTool(s, "get_ax_state", ["pid": 1, "focus": "", "focus_role": ""])
        #expect(!empty.text.contains("focus 命中") && empty.text.contains("元素 3"))
    }

    @Test func focusWithNoMatchIsAnInformativeResultNotAnError() {
        reader.tree = .success(TreeReading(root: AXNode(role: "AXWindow"), truncated: true))
        let r = callTool(server, "get_ax_state", ["pid": 1, "focus": "不存在"])
        #expect(!r.isError)
        #expect(r.text.contains("没有元素匹配 focus"))
        #expect(r.text.contains("树不完整"))  // 截断时要提醒"可能只是没读到"
    }

    @Test func focusMustBeAString() {
        let r = callTool(server, "get_ax_state", ["pid": 1, "focus": 5])
        #expect(r.isError && r.text.hasPrefix("[invalid_argument]"))
        #expect(reader.treeCalls.isEmpty)
    }
}

extension JSONValue {
    var arrayFirst: JSONValue? {
        if case .array(let a) = self { return a.first }
        return nil
    }
    var arrayValues: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
}

/// 动作档：`click` 默认不暴露，开启后经令牌与句柄执行，返回观察到的效果。
@Suite struct ActionToolTests {
    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
        var settle: DesktopSession.Settle {
            DesktopSession.Settle(interval: 0.2, cap: 3.0, sleep: { self.now += $0 }, now: { self.now })
        }
    }

    static let tree = TreeReading(
        root: AXNode(
            role: "AXWindow", title: "主窗口", childCount: 2,
            children: [AXNode(role: "AXButton", title: "确定"), AXNode(role: "AXTextField", value: "abc")]),
        truncated: false)

    func rig(actions: Bool, apps: [AppInfo]? = nil) -> (MCPServerTests, MCPServer, FakeReader) {
        let t = MCPServerTests()
        let reader = FakeReader()
        reader.tree = .success(Self.tree)
        if let apps { reader.apps = .success(apps) }
        let server = MCPServer(
            reader: reader, serverVersion: "test", actionsEnabled: actions, policy: PolicyGate(),
            settle: Clock().settle)
        return (t, server, reader)
    }

    func token(from reply: ToolReply) -> String {
        let head = reply.text.split(separator: "\n").first.map(String.init) ?? ""
        let parts = head.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: "令牌"), i + 1 < parts.count else { return "" }
        return parts[i + 1]
    }

    func toolNames(_ t: MCPServerTests, _ s: MCPServer) -> [String] {
        let r = t.request(s, "tools/list")
        return r["result"]?["tools"]?.arrayValues?.compactMap { $0["name"]?.stringValue } ?? []
    }

    @Test func clickIsHiddenAndRejectedByDefault() {
        let (t, s, reader) = rig(actions: false)
        #expect(toolNames(t, s) == ["check_permissions", "list_apps", "get_ax_state"])
        let r = t.request(s, "tools/call", params: ["name": "click", "arguments": ["token": "x", "handle": 1]])
        #expect(r["error"]?["code"] == .int(-32602))  // 与未知工具同样处理
        #expect(reader.actionCalls.isEmpty)
        let hello = t.request(s, "initialize", params: ["protocolVersion": "2025-06-18"])
        #expect(hello["result"]?["instructions"]?.stringValue?.contains("只读档") == true)
    }

    @Test func clickIsExposedWithTruthfulAnnotationsWhenEnabled() {
        let (t, s, _) = rig(actions: true)
        #expect(toolNames(t, s).contains("click"))
        let tools = t.request(s, "tools/list")["result"]?["tools"]?.arrayValues ?? []
        let click = tools.first { $0["name"]?.stringValue == "click" }
        #expect(click?["annotations"]?["readOnlyHint"] == .bool(false))
        #expect(click?["annotations"]?["destructiveHint"] == .bool(true))
        let read = tools.first { $0["name"]?.stringValue == "get_ax_state" }
        #expect(read?["annotations"]?["readOnlyHint"] == .bool(true))
        let hello = t.request(s, "initialize", params: ["protocolVersion": "2025-06-18"])
        #expect(hello["result"]?["instructions"]?.stringValue?.contains("动作档") == true)
    }

    @Test func readThenClickReportsTheObservedEffect() {
        let (t, s, reader) = rig(actions: true)
        let read = t.callTool(s, "get_ax_state", ["pid": 42])
        let tok = token(from: read)
        #expect(tok.hasPrefix("s"))
        #expect(read.text.contains("用 click(token, handle) 点击，或用 type_text / press_key 输入"))
        let r = t.callTool(s, "click", ["token": .string(tok), "handle": 2])
        #expect(!r.isError)
        #expect(r.text.contains("AXButton#2"))
        #expect(r.text.contains("effect: delivered=true observed=true converged=true treeChanged=false"))
        #expect(r.text.contains("疑似空操作"))
        #expect(reader.actionCalls.count == 1)
        #expect(reader.actionCalls[0].locator.target.title == "确定")
    }

    @Test func inputToolsAreExposedWithTruthfulAnnotations() {
        let (t, s, _) = rig(actions: true)
        let names = toolNames(t, s)
        #expect(names.contains("type_text"))
        #expect(names.contains("press_key"))
        let tools = t.request(s, "tools/list")["result"]?["tools"]?.arrayValues ?? []
        for name in ["type_text", "press_key"] {
            let tool = tools.first { $0["name"]?.stringValue == name }
            #expect(tool?["annotations"]?["readOnlyHint"] == .bool(false))
            #expect(tool?["annotations"]?["destructiveHint"] == .bool(true))
        }
    }

    @Test func typeTextUsesTokenAndReportsTheObservedEffect() {
        let (t, s, reader) = rig(actions: true)
        let read = t.callTool(s, "get_ax_state", ["pid": 42])
        let r = t.callTool(s, "type_text", [
            "token": .string(token(from: read)), "handle": 3, "text": "hello",
        ])
        #expect(!r.isError)
        #expect(r.text.contains("AXTextField#3"))
        #expect(r.text.contains("投递输入"))
        #expect(r.text.contains("effect: delivered=true"))
        #expect(reader.typed.count == 1)
        #expect(reader.typed[0].text == "hello")
    }

    @Test func pressKeyUsesTokenAndReportsTheObservedEffect() {
        let (t, s, reader) = rig(actions: true)
        let read = t.callTool(s, "get_ax_state", ["pid": 42])
        let r = t.callTool(s, "press_key", [
            "token": .string(token(from: read)), "handle": 3, "key": "Return",
        ])
        #expect(!r.isError)
        #expect(r.text.contains("投递按键"))
        #expect(reader.pressed.count == 1)
        #expect(reader.pressed[0].key == "Return")
    }

    @Test func inputArgumentsAreValidated() {
        let (t, s, _) = rig(actions: true)
        let tok = token(from: t.callTool(s, "get_ax_state", ["pid": 42]))
        for (name, args): (String, JSONValue) in [
            ("type_text", ["token": .string(tok), "handle": 3]),
            ("type_text", ["token": .string(tok), "handle": 3, "text": ""]),
            ("type_text", ["token": .string(tok), "handle": 3, "text": "x", "extra": true]),
            ("press_key", ["token": .string(tok), "handle": 3]),
            ("press_key", ["token": .string(tok), "handle": 3, "key": ""]),
            ("press_key", ["token": .string(tok), "handle": 0, "key": "Return"]),
        ] {
            let r = t.callTool(s, name, args)
            #expect(r.isError && r.text.hasPrefix("[invalid_argument]"), "\(name) \(args)")
        }
    }

    @Test func staleTokenGivesAClassifiedErrorWithGuidance() {
        let (t, s, reader) = rig(actions: true)
        let r = t.callTool(s, "click", ["token": "nope", "handle": 1])
        #expect(r.isError)
        #expect(r.text.hasPrefix("[stale_snapshot]"))
        #expect(r.text.contains("重新调用 get_ax_state"))
        #expect(reader.actionCalls.isEmpty)
    }

    @Test func handleOutsideTheSnapshotIsElementGone() {
        let (t, s, _) = rig(actions: true)
        let tok = token(from: t.callTool(s, "get_ax_state", ["pid": 42]))
        let r = t.callTool(s, "click", ["token": .string(tok), "handle": 99])
        #expect(r.isError && r.text.hasPrefix("[element_gone]"))
    }

    @Test func deniedAppIsExplainedUpFrontAndRefusedOnClick() {
        let terminal = [AppInfo(pid: 42, name: "终端", bundleId: "com.apple.Terminal")]
        let (t, s, reader) = rig(actions: true, apps: terminal)
        let read = t.callTool(s, "get_ax_state", ["pid": 42])
        #expect(!read.isError)  // 读取不受策略限制
        #expect(read.text.contains("⚠️ 策略：终端 属于拒绝类目 runs_shell_commands"))
        let r = t.callTool(s, "click", ["token": .string(token(from: read)), "handle": 2])
        #expect(r.isError && r.text.hasPrefix("[policy_denied]"))
        #expect(r.text.contains("retry=no"))
        #expect(r.text.contains("不要重试"))
        #expect(reader.actionCalls.isEmpty)
    }

    @Test func unsupportedElementIsReportedAsSuch() {
        let (t, s, reader) = rig(actions: true)
        reader.action = .failure(.unsupportedOperation("不支持 AXPress"))
        let tok = token(from: t.callTool(s, "get_ax_state", ["pid": 42]))
        let r = t.callTool(s, "click", ["token": .string(tok), "handle": 3])
        #expect(r.isError && r.text.hasPrefix("[unsupported_operation]"))
    }

    @Test func argumentsAreValidated() {
        let (t, s, _) = rig(actions: true)
        for args: JSONValue in [
            [:], ["token": "x"], ["handle": 1], ["token": "x", "handle": 0], ["token": "x", "handle": "1"],
            ["token": "x", "handle": 1, "extra": true], ["token": "", "handle": 1],
        ] {
            let r = t.callTool(s, "click", args)
            #expect(r.isError && r.text.hasPrefix("[invalid_argument]"), "\(args)")
        }
    }

    @Test func readOnlyToolDescriptionsStayReadOnly() {
        // 读取工具的描述不得暗示会改变状态；动作工具的描述必须如实说明。
        #expect(ScuTool.getAXState.description.contains("只读"))
        #expect(ScuTool.click.description.contains("会改变应用的状态"))
        #expect(ScuTool.click.isAction && !ScuTool.getAXState.isAction)
    }
}
