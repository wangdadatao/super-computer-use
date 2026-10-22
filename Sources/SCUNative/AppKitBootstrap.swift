import AppKit

/// sidecar 是命令行进程，但 AppKit 的共享实例与窗口 API 只能在主线程使用。
/// 入口是同步的 main 循环；这里把“必须为主线程”的假设集中成一个显式断言，
/// 避免截图、指示环等调用点各自处理，行为不一致。
enum AppKitBootstrap {
    static func ensureApplication() {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }
}
