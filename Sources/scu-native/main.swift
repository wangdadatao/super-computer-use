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

do {
    try NativeServer(socketPath: socketPath, protocolVersion: version).run()
} catch {
    FileHandle.standardError.write(Data("scu-native 失败：\(error)\n".utf8))
    exit(1)
}
