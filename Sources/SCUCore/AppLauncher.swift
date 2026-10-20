import AppKit
import Foundation
import SCUWire

/// 启动应用。抽成协议是为了让接入层测试不真的打开应用。
public protocol AppLauncher: Sendable {
    /// 只解析，不启动。找不到时返回 nil。
    func resolve(_ identifier: String) throws -> AppInfo?
    /// 启动（或激活已在运行的应用），返回 pid/名称/bundle id。
    func launch(_ identifier: String, activate: Bool) throws -> AppInfo
}

/// 基于 LaunchServices（`NSWorkspace`）与 `/usr/bin/open` 的实现。
///
/// `identifier` 支持 bundle id、应用显示名、`.app` 路径。
/// 启动前先解析并让调用方做策略检查；这里不替调用方判断拒绝类目。
public struct WorkspaceAppLauncher: AppLauncher {
    public init() {}

    public func resolve(_ identifier: String) throws -> AppInfo? {
        guard let url = resolveURL(identifier) else { return nil }
        return info(for: url)
    }

    public func launch(_ identifier: String, activate: Bool) throws -> AppInfo {
        if let existing = try resolve(identifier), existing.pid > 0,
            let app = NSRunningApplication(processIdentifier: existing.pid)
        {
            if activate { app.activate(options: [.activateIgnoringOtherApps]) }
            return existing
        }

        let arguments: [String]
        if let url = resolveURL(identifier) {
            arguments = [url.path]
        } else if identifier.contains("."), !identifier.contains("/") {
            arguments = ["-b", identifier]
        } else {
            arguments = ["-a", identifier]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw WireError.actionFailed("无法执行 open：\(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WireError.actionFailed("open 失败（退出码 \(process.terminationStatus)）：\(identifier)")
        }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let app = runningApplication(for: identifier) {
                if activate { app.activate(options: [.activateIgnoringOtherApps]) }
                return AppInfo(
                    pid: app.processIdentifier, name: app.localizedName ?? identifier,
                    bundleId: app.bundleIdentifier)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw WireError.actionFailed("应用启动后 10 秒内没有出现在运行列表：\(identifier)")
    }

    // MARK: - 解析

    private func resolveURL(_ identifier: String) -> URL? {
        let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if raw.hasPrefix("/") || FileManager.default.fileExists(atPath: raw) {
            let url = URL(fileURLWithPath: raw)
            guard url.pathExtension == "app" || Bundle(url: url) != nil else { return nil }
            return url
        }

        if raw.contains("."), !raw.contains("/") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: raw) { return url }
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == raw || $0.bundleIdentifier == raw
        }), let url = running.bundleURL {
            return url
        }

        let name = raw.hasSuffix(".app") ? raw : raw + ".app"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            home + "/Applications",
        ]
        for dir in dirs {
            let path = dir + "/" + name
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func info(for url: URL) -> AppInfo {
        let bundle = Bundle(url: url)
        let bundleId = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let running = bundleId.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        } ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
        return AppInfo(pid: running?.processIdentifier ?? 0, name: name, bundleId: bundleId)
    }

    private func runningApplication(for identifier: String) -> NSRunningApplication? {
        if identifier.contains("."), !identifier.contains("/") {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                return app
            }
        }
        if let url = resolveURL(identifier), let bundleId = Bundle(url: url)?.bundleIdentifier,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        {
            return app
        }
        let name = (try? resolve(identifier))?.name ?? identifier
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName == name || $0.bundleURL?.path == identifier
        }
    }
}
