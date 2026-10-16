import Foundation
import SCUNative
import SCUWire

// 原生进程入口。由 scu 启动：scu-native --socket <path> [--protocol-version <n>]
// --protocol-version 仅供测试版本错配路径，正常运行不应传。
var socketPath: String?
var version = scuNativeProtocolVersion
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--socket": socketPath = args.popFirst()
    case "--protocol-version": version = Int(args.popFirst() ?? "") ?? version
    default:
        FileHandle.standardError.write(Data("未知参数：\(arg)\n".utf8))
        exit(64)
    }
}
guard let socketPath else {
    FileHandle.standardError.write(Data("用法：scu-native --socket <path>\n".utf8))
    exit(64)
}

/// 退出时回收协议层为本进程创建的 socket 目录（`scu-<随机>`，0700）。
/// 协议层被 SIGKILL 时它自己的清理不会运行，这是唯一能把目录收走的一方。
/// 只删名字以 `scu-` 开头的**空**目录：`rmdir` 对非空目录会失败，不会误删别人的数据。
func removeOwnSocketDirectory(socketPath: String) {
    let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
    guard dir.lastPathComponent.hasPrefix("scu-") else { return }
    rmdir(dir.path)
}

do {
    try NativeServer(socketPath: socketPath, protocolVersion: version).run()
    removeOwnSocketDirectory(socketPath: socketPath)
} catch {
    removeOwnSocketDirectory(socketPath: socketPath)
    FileHandle.standardError.write(Data("scu-native 失败：\(error)\n".utf8))
    exit(1)
}
