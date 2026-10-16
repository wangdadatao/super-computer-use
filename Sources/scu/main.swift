import Foundation
import SCUCore
import SCUWire

// P0 命令行入口，代替后续的 MCP 接入层。
//   scu permissions
//   scu apps
//   scu dump --pid <pid> [--depth <n>] [--json]
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

func run(command: String, args: [String]) throws {
    // 先校验参数，再启动 sidecar：用法错误不应拉起子进程。
    var pid: Int32 = 0
    var depth = 12
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

    default:  // dump
        guard case .tree(let root) = try client.call(.dumpTree(pid: pid, maxDepth: depth)) else {
            throw CLIExit(code: 1, message: "应答类型错误")
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
            Data("用法：scu permissions | apps | dump --pid <pid> [--depth <n>] [--json]\n".utf8))
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
