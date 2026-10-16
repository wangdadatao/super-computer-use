// swift-tools-version: 6.0
//
// SCU P0 脚手架。边界对应 docs/architecture/system_overview.md 的四层：
//   SCUWire    两进程之间的线协议（帧、版本、消息类型）
//   SCUNative  原生层（AX 树、权限检测），由 scu-native 进程承载
//   SCUCore    协议层（句柄注册表、令牌、失效检测），由 scu 进程承载
//   SCUMCP     接入层：MCP stdio 服务（JSON-RPC、工具目录），只依赖协议层
//   scu        命令行入口：诊断命令与 `scu mcp`
// 决策见 docs/decisions/adr_0013_p0_vertical_slice.md。
import PackageDescription

let package = Package(
    name: "SuperComputerUse",
    platforms: [.macOS("14.4")],  // 与 README「平台范围」一致
    products: [
        .executable(name: "scu", targets: ["scu"]),
        .executable(name: "scu-native", targets: ["scu-native"]),
    ],
    targets: [
        .target(name: "SCUWire"),
        .target(name: "SCUNative", dependencies: ["SCUWire"]),
        .target(name: "SCUCore", dependencies: ["SCUWire"]),
        .executableTarget(name: "scu-native", dependencies: ["SCUNative", "SCUWire"]),
        .target(name: "SCUMCP", dependencies: ["SCUCore", "SCUWire"]),
        .executableTarget(name: "scu", dependencies: ["SCUCore", "SCUMCP", "SCUWire"]),
        .testTarget(name: "SCUWireTests", dependencies: ["SCUWire"]),
        .testTarget(name: "SCUNativeTests", dependencies: ["SCUNative", "SCUWire"]),
        .testTarget(name: "SCUCoreTests", dependencies: ["SCUCore", "SCUWire"]),
        .testTarget(name: "SCUMCPTests", dependencies: ["SCUMCP", "SCUCore", "SCUWire"]),
    ],
    swiftLanguageModes: [.v6]
)
