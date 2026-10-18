import AppKit

// 验证用的夹具应用：一个只有按钮与标签的 AppKit 窗口，行为可预知，用来对 SCU 的点击、令牌、效果摘要
// 做端到端验证。**不是产品的一部分**，只被测试拉起；见 docs/operations/testing.md。
//
// 每个控件的预期（测试按标题找到它们）：
//   Increment   点击后立即改变标签文本并停止
//   NoOp        点击后什么都不变
//   Disabled    被禁用
//   AddRow      点击后在下方增加一个按钮（子节点数变化）
//   Delayed     点击后 2 秒才改变状态标签（模拟慢加载）
//   Animate     点击后状态标签每 100 毫秒变化一次，持续 20 秒（模拟无限动画）
//   Busy        点击后后台忙 3 秒，界面不变（已知局限的场景）
//   Covered     被一个不透明视图盖住；点击它同样让计数加一
//
// 安全网：父进程消失或 3 分钟后自行退出，不会遗留窗口。

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let count = NSTextField(labelWithString: "count: 0")
    let status = NSTextField(labelWithString: "status: idle")
    let rows = NSStackView()
    var n = 0
    var rowN = 0
    var tick = 0
    var timer: Timer?

    func makeButton(_ title: String, id: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.setAccessibilityIdentifier(id)
        return b
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        count.setAccessibilityIdentifier("count")
        status.setAccessibilityIdentifier("status")
        rows.orientation = .vertical
        rows.alignment = .leading

        let disabled = makeButton("Disabled", id: "disabled", action: #selector(noop))
        disabled.isEnabled = false
        let stack = NSStackView(views: [
            count, status,
            makeButton("Increment", id: "inc", action: #selector(inc)),
            makeButton("NoOp", id: "noop", action: #selector(noop)),
            disabled,
            makeButton("AddRow", id: "add", action: #selector(addRow)),
            makeButton("Delayed", id: "delayed", action: #selector(delayed)),
            makeButton("Animate", id: "animate", action: #selector(animate)),
            makeButton("Busy", id: "busy", action: #selector(busy)),
            rows,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 520))
        stack.frame = NSRect(x: 10, y: 90, width: 340, height: 420)
        content.addSubview(stack)

        // 被遮挡的按钮：真实按钮在下，不透明的盒子盖在上面。
        let zone = NSView(frame: NSRect(x: 10, y: 10, width: 200, height: 60))
        let covered = makeButton("Covered", id: "covered", action: #selector(inc))
        covered.frame = zone.bounds
        let cover = NSBox(frame: zone.bounds)
        cover.boxType = .custom
        cover.fillColor = .windowBackgroundColor
        cover.borderWidth = 0
        zone.addSubview(covered)
        zone.addSubview(cover)
        content.addSubview(zone)

        window = NSWindow(
            contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SCU Fixture"
        window.contentView = content
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.orderFrontRegardless()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if getppid() == 1 { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    @objc func inc() {
        n += 1
        count.stringValue = "count: \(n)"
    }

    @objc func noop() {}

    @objc func addRow() {
        rowN += 1
        rows.addArrangedSubview(makeButton("Row \(rowN)", id: "row\(rowN)", action: #selector(noop)))
    }

    @objc func delayed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated { self?.status.stringValue = "status: loaded" }
        }
    }

    @objc func animate() {
        timer?.invalidate()
        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                self.status.stringValue = "tick \(self.tick)"
                if self.tick >= 200 { self.timer?.invalidate() }
            }
        }
    }

    @objc func busy() {
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(3)
            var x = 0.0
            while Date() < end { x += sin(x) }  // 空转，不改变任何界面
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Fixture()
app.delegate = delegate
app.run()
