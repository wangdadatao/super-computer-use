import Foundation
import Dispatch
import SCUCore
import SCUMCP
import SCUWire

// 命令行入口：诊断命令，以及 `scu mcp`（MCP stdio 服务）。
//   scu mcp [--actions]                以 MCP stdio 服务运行；默认只读档，--actions 额外暴露 click，见 docs/interfaces/mcp_surface.md
//   scu permissions
//   scu apps
//   scu dump --pid <pid> [--depth <n>] [--json]
//   scu identity --pid <pid> [--depth <n>] [--show-k4] [--by-role]
//
// 退出码：0 成功；1 失败；2 缺系统权限；64 用法错误。
// 所有失败路径都通过抛出 CLIExit 回到 main，**不在 run 内调用 exit()**：
// exit() 会绕过 defer 与 deinit，导致 sidecar 未终止、临时目录泄漏。

struct CLIExit: Error {
    var code: Int32
    var message: String?
}

func usage(_ message: String) -> CLIExit { CLIExit(code: 64, message: message) }

func nativeExecutableURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["SCU_NATIVE"] {
        // 仅用于开发：可指向任意可执行文件，唯一的兜底是版本握手。不要在生产环境设置。
        FileHandle.standardError.write(Data("[dev] SCU_NATIVE 覆盖了原生进程路径：\(override)\n".utf8))
        return URL(fileURLWithPath: override)
    }
    let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return me.deletingLastPathComponent().appendingPathComponent("scu-native")
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func parseBudget(_ args: [String]) throws -> Int {
    guard let b = option("--budget-ms", in: args) else { return scuDefaultTreeBudgetMs }
    guard let n = Int(b), scuTreeBudgetMsRange.contains(n) else {
        throw usage("--budget-ms 必须在 \(scuTreeBudgetMsRange)")
    }
    return n
}

/// 读树的客户端等待上限 = 时间预算 + 余量（单次 AX 调用最多再耗 2 秒，加上编码与传输）。
func treeTimeoutMs(_ budgetMs: Int) -> Int32 { Int32(budgetMs + 10_000) }

let scuVersion = "0.0.1-p0"

/// 以 MCP stdio 服务运行。**stdout 只允许出现协议消息**：任何诊断都写 stderr。
func runMCP(actions: Bool) {
    // 宿主关闭管道后继续写会触发 SIGPIPE；改为让 write 返回错误，由循环正常退出并清理。
    signal(SIGPIPE, SIG_IGN)

    // 被信号终止时 defer 不会执行：用信号源兜底，终止 sidecar 并删除 socket 目录。
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            NativeClient.terminateAllForShutdown()
            exit(128 + sig)
        }
        src.resume()
        sources.append(src)
    }

    let session = NativeSession(nativeExecutable: nativeExecutableURL())
    defer { session.close() }
    // 策略的宿主判定：SCU 自身与启动它的进程链都是拒绝目标（policy_layer.md）。
    let server = MCPServer(
        reader: session, serverVersion: scuVersion, actionsEnabled: actions, policy: PolicyGate.forCurrentProcess())
    server.run(
        readLine: { Swift.readLine(strippingNewline: true) },
        write: { line in
            var bytes = Array((line + "\n").utf8)[...]
            while !bytes.isEmpty {
                let n = bytes.withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                bytes = bytes.dropFirst(n)
            }
            return true
        })
    withExtendedLifetime(sources) {}
}

func run(command: String, args: [String]) throws {
    // 先校验参数，再启动 sidecar：用法错误不应拉起子进程。
    var pid: Int32 = 0
    var depth = 12
    var budgetMs = scuDefaultTreeBudgetMs
    if command == "dump" {
        guard let pidText = option("--pid", in: args), let p = Int32(pidText) else {
            throw usage("缺少或无效的 --pid")
        }
        pid = p
        if let d = option("--depth", in: args) {
            guard let n = Int(d), (0...scuMaxTreeDepth).contains(n) else {
                throw usage("--depth 必须在 0...\(scuMaxTreeDepth)")
            }
            depth = n
        }
        budgetMs = try parseBudget(args)
    } else if command == "identity" {
        guard let pidText = option("--pid", in: args), let p = Int32(pidText) else {
            throw usage("缺少或无效的 --pid")
        }
        pid = p
        depth = 24
        if let d = option("--depth", in: args) {
            guard let n = Int(d), (0...scuMaxTreeDepth).contains(n) else {
                throw usage("--depth 必须在 0...\(scuMaxTreeDepth)")
            }
            depth = n
        }
        budgetMs = try parseBudget(args)
    } else if command == "mcp" {
        // 先校验参数再启动：用法错误不应拉起子进程。
        let unknown = args.filter { $0 != "--actions" }
        if let bad = unknown.first { throw usage("scu mcp 不认识的参数：\(bad)（只支持 --actions）") }
        runMCP(actions: args.contains("--actions"))
        return
    } else if command != "permissions" && command != "apps" {
        throw usage("未知命令：\(command)")
    }

    let client = try NativeClient(nativeExecutable: nativeExecutableURL())
    defer { client.close() }

    switch command {
    case "permissions":
        guard case .permissions(let ax) = try client.call(.checkPermissions) else {
            throw CLIExit(code: 1, message: "应答类型错误")
        }
        print("辅助功能：\(ax ? "已授予" : "未授予")")
        if !ax { throw CLIExit(code: 2, message: nil) }

    case "apps":
        guard case .apps(let apps) = try client.call(.listApps) else {
            throw CLIExit(code: 1, message: "应答类型错误")
        }
        for a in apps { print("\(a.pid)\t\(a.name)\t\(a.bundleId ?? "-")") }

    case "identity":
        guard case .tree(let root, let truncated) = try client.call(
            .dumpTree(pid: pid, maxDepth: depth, budgetMs: budgetMs), timeoutMs: treeTimeoutMs(budgetMs))
        else {
            throw CLIExit(code: 1, message: "应答类型错误")
        }
        if truncated {
            FileHandle.standardError.write(Data("⚠️ 已截断：\(budgetMs) 毫秒预算耗尽，分布只覆盖已读取部分。\n".utf8))
        }
        // 基线：只呈现各档分布，不给成败结论（ADR-0013「基线先行」）。
        print("匹配键档位分布。保守口径：不把 _NS:<数字> 算作显式标识符")
        print(IdentityAnalyzer.report(root, policy: .conservative).text(title: "[A] 保守 · 仅 title（ADR-0013 冻结口径）"))
        print(IdentityAnalyzer.report(root, policy: .inclusive).text(title: "[B] 计入 _NS:<数字> · 仅 title"))
        print(IdentityAnalyzer.report(root, policy: .conservative, labels: .titleOrDescription)
            .text(title: "[C] 保守 · title 或 description（实验）"))
        if args.contains("--by-role") {
            print("\n可交互元素按 role 拆分（口径 C）：")
            print(IdentityAnalyzer.report(root, policy: .conservative, labels: .titleOrDescription).byRoleText())
        }
        if args.contains("--show-k4") {
            print("\n可交互元素中落入 K4 的元素：")
            for e in IdentityAnalyzer.analyze(root, labels: .titleOrDescription) where e.isInteractive && e.matchLevel == .k4 {
                print("  \(e.role) title=\(e.title.map { "\"\($0)\"" } ?? "-") id=\(e.identifier ?? "-") path=\(e.path)")
            }
        }
        FileHandle.standardError.write(
            Data("深度上限 \(depth)：更深的节点未读取，分布只覆盖已读取部分。\n".utf8))

    default:  // dump
        guard case .tree(let root, let truncated) = try client.call(
            .dumpTree(pid: pid, maxDepth: depth, budgetMs: budgetMs), timeoutMs: treeTimeoutMs(budgetMs))
        else {
            throw CLIExit(code: 1, message: "应答类型错误")
        }
        if truncated {
            FileHandle.standardError.write(Data("⚠️ 已截断：\(budgetMs) 毫秒预算耗尽，树不完整。\n".utf8))
        }
        if args.contains("--json") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(root), as: UTF8.self))
        } else {
            print(TreeFormatter.text(root))
            FileHandle.standardError.write(Data((FieldCoverage(root).summary + "\n").utf8))
        }
    }
}

func main() -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else {
        FileHandle.standardError.write(
            Data("用法：scu mcp [--actions] | permissions | apps | dump|identity --pid <pid> [--depth <n>] [--budget-ms <n>] [--json|--show-k4|--by-role]\n".utf8))
        return 64
    }
    do {
        try run(command: command, args: Array(argv.dropFirst()))
        return 0
    } catch let e as CLIExit {
        if let m = e.message { FileHandle.standardError.write(Data((m + "\n").utf8)) }
        return e.code
    } catch let e as WireError {
        // 按 code 分支，不解析 message（error_taxonomy.md）。
        FileHandle.standardError.write(Data("[\(e.code)] \(e.message)（retry=\(e.retry)）\n".utf8))
        return e.code == "system_permission_missing" ? 2 : 1
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    }
}

// run() 已返回，所有 defer 都已执行，此处 exit 是安全的。
exit(main())
