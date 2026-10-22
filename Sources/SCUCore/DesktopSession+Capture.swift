import Foundation
import SCUWire

extension DesktopSession {
    /// 对当前令牌的目标窗口截图。返回图像、元数据与落在截图窗口内的标签。
    ///
    /// 截图不改变令牌；但截图绑定窗口位置/缩放，供后续坐标动作判断是否过期。
    public func captureScreenshot(token: String) throws -> SessionScreenshot {
        guard let r = records[token] else {
            throw WireError.staleSnapshot("令牌 \(token) 未签发或已被丢弃，请重新读取界面。")
        }
        switch r.status {
        case .switched:
            throw WireError.targetSwitched("令牌 \(token) 属于已被切换走的目标（pid \(r.pid)），请重新读取并绑定目标。")
        case .stale:
            throw WireError.staleSnapshot("令牌 \(token) 已失效：界面结构已变化，请重新读取界面。")
        case .current:
            break
        }
        guard let snap = r.snapshot else { throw WireError.internalError("当前令牌缺少快照") }
        try authorizer.authorizeRead(try identity(for: r), pid: r.pid)
        let capture = try reader.captureWindow(pid: r.pid, windowTitle: r.windowTitle)
        // 绑定**实际被截到的窗口**。令牌没有指定窗口时，原生层会选最大窗口；
        // 若这里仍存令牌的 nil，后续坐标动作会重新选一次，可能落到另一个窗口。
        let boundWindowTitle = capture.windowTitle ?? r.windowTitle
        let labels = snap.entries.enumerated().compactMap { index, entry -> ElementTable.Label? in
            guard let text = entry.label, let frame = entry.node.frame else { return nil }
            // 只保留落在截图窗口内的标签；截图外的标签画不出来，也不应该参与坐标语义。
            let window = capture.windowFrame
            let intersects =
                frame.x < window.x + window.width
                && frame.x + frame.width > window.x
                && frame.y < window.y + window.height
                && frame.y + frame.height > window.y
            guard intersects else { return nil }
            return ElementTable.Label(
                text: text, handle: index + 1, role: entry.node.role,
                title: entry.node.title, frame: frame)
        }
        screenshotCounter += 1
        let id = "g\(nonce).\(screenshotCounter)"
        screenshotBindings[id] = ScreenshotBinding(
            token: token, windowTitle: boundWindowTitle, windowFrame: capture.windowFrame,
            scale: capture.scale, width: capture.width, height: capture.height, png: capture.png)
        screenshotOrder.append(id)
        while screenshotOrder.count > 16 {
            screenshotBindings[screenshotOrder.removeFirst()] = nil
        }
        return SessionScreenshot(id: id, capture: capture, labels: labels)
    }

    /// 在截图坐标 (x, y) 点击。坐标以截图左上角为原点，单位是图像像素。
    ///
    /// 截图必须属于当前令牌，且窗口位置/缩放未变；否则拒绝。
    /// 点击后只观察 AX 树是否变化；坐标点击的像素级变化留给截图 diff。
    private func coordinateContext(
        token: String, screenshotID: String
    ) throws -> (Record, Snapshot, ScreenshotBinding) {
        guard let r = records[token] else {
            throw WireError.staleSnapshot("令牌 \(token) 未签发或已被丢弃，请重新读取界面。")
        }
        switch r.status {
        case .switched:
            throw WireError.targetSwitched("令牌 \(token) 属于已被切换走的目标（pid \(r.pid)），请重新读取并绑定目标。")
        case .stale:
            throw WireError.staleSnapshot("令牌 \(token) 已失效：界面结构已变化，请重新读取界面。")
        case .current:
            break
        }
        guard let snap = r.snapshot else { throw WireError.internalError("当前令牌缺少快照") }
        guard let binding = screenshotBindings[screenshotID], binding.token == token else {
            throw WireError.staleGeometry("截图 \(screenshotID) 不存在、已过期或不属于令牌 \(token)，请重新 get_screenshot。")
        }

        try authorizer.authorizeAction(try identity(for: r), pid: r.pid)
        return (r, snap, binding)
    }

    /// 动作前再取一次当前窗口几何：截图后窗口可能移动/缩放，或同名窗口换了一个。
    /// 只按标题投递会把旧截图的坐标算到新位置上；先拒绝，要求重新截图。
    func validateCoordinateWindow(_ binding: ScreenshotBinding, pid: Int32) throws {
        let current = try reader.captureWindow(pid: pid, windowTitle: binding.windowTitle)
        guard current.windowFrame == binding.windowFrame, current.scale == binding.scale,
            current.width == binding.width, current.height == binding.height
        else {
            throw WireError.staleGeometry("截图后窗口位置/缩放已变化，请重新 get_screenshot。")
        }
    }

    /// 丢弃某个令牌的全部截图绑定。动作结果未知或令牌失效后，旧截图不能再用于坐标动作。
    func removeScreenshots(for token: String) {
        let ids = Set(screenshotBindings.compactMap { $0.value.token == token ? $0.key : nil })
        guard !ids.isEmpty else { return }
        screenshotBindings = screenshotBindings.filter { !ids.contains($0.key) }
        screenshotOrder.removeAll { ids.contains($0) }
    }

    /// 动作的统一收尾：结果未知时作废令牌与截图绑定，再把错误原样抛出。
    func performCoordinate(
        token: String, _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch {
            discardAfterUnknownOutcome(error, token: token)
            throw error
        }
    }

    func checkPoint(_ x: Double, _ y: Double, in binding: ScreenshotBinding) throws {
        guard x >= 0, y >= 0, x < Double(binding.width), y < Double(binding.height) else {
            throw WireError.invalidCoordinates(
                "坐标 (\(x), \(y)) 不在截图 \(binding.width)×\(binding.height) 范围内。")
        }
    }

    func globalPoint(x: Double, y: Double, binding: ScreenshotBinding) -> (x: Double, y: Double) {
        (binding.windowFrame.x + x / binding.scale, binding.windowFrame.y + y / binding.scale)
    }

    /// 把结构摘要限定到截图绑定的窗口子树。
    ///
    /// 令牌没有指定窗口时，`readState` 的读取根是整个应用；直接用全局摘要判断这次
    /// 坐标动作的效果，会把其他窗口的变化也算进来。这里以 frame 优先、标题兜底定位
    /// 绑定窗口，只比较该窗口的子树。两者都找不到（例如无标题窗口）时返回 nil，
    /// 调用方退回全局判断。
    static func windowScopedDigest(
        _ entries: [ElementTable.Entry], binding: ScreenshotBinding
    ) -> Int? {
        let windows = entries.enumerated().filter { $0.element.node.role == "AXWindow" }
        let chosen =
            windows.first { $0.element.node.frame == binding.windowFrame }
            ?? binding.windowTitle.flatMap { title in
                windows.first { $0.element.node.title == title }
            }
        guard let chosen else { return nil }
        let end = chosen.offset + chosen.element.size
        guard end <= entries.count else { return nil }
        return structuralDigest(
            Array(entries[chosen.offset..<end]), depthBase: chosen.element.depth)
    }

    func observeCoordinate(
        token: String, r: Record, snap: Snapshot, binding: ScreenshotBinding, start: Date
    ) -> CoordinateReport {
        settle.sleep(settle.interval)
        var observed = false
        var changed: Bool?
        var invalidated = false
        do {
            // 观察读取仍用令牌自己的窗口根：readState 的令牌复用/失效判断必须与令牌的
            // windowTitle 一致。若这里改用绑定窗口，令牌没有指定窗口时每次观察都会因
            // windowTitle 不同而签发新令牌，把“无变化”误报成“结构已变化”。
            // 变化比较则限定到截图绑定的窗口子树，避免其他窗口的变化算到这次动作上。
            let after = try readState(
                pid: r.pid, maxDepth: snap.maxDepth, budgetMs: snap.budgetMs,
                windowTitle: r.windowTitle)
            observed = true
            invalidated = after.token != SnapshotToken(token)
            let afterEntries = ElementTable.flatten(after.reading.root)
            if let before = Self.windowScopedDigest(snap.entries, binding: binding),
                let afterDigest = Self.windowScopedDigest(afterEntries, binding: binding)
            {
                changed = before != afterDigest
            } else {
                // 绑定窗口定位不到（例如无标题窗口）：只能退回全局判断。
                // 全局也没变时不要断言“没变化”，报未知比误报 noOp 更安全。
                changed = invalidated ? true : nil
            }
        } catch {
            observed = false
        }

        var screenshotChanged: Bool?
        var diffRatio: Double?
        var geometryChanged = false
        if let after = try? reader.captureWindow(pid: r.pid, windowTitle: binding.windowTitle) {
            if after.width != binding.width || after.height != binding.height
                || after.windowFrame != binding.windowFrame || after.scale != binding.scale
            {
                geometryChanged = true
            } else if let ratio = ScreenshotDiff.changedRatio(before: binding.png, after: after.png) {
                diffRatio = ratio
                screenshotChanged = ratio > 0.001
            }
        }

        let noOp = observed && changed == false && (screenshotChanged == false || screenshotChanged == nil)
        return CoordinateReport(
            pid: r.pid, observed: observed, treeChanged: changed,
            screenshotChanged: screenshotChanged, diffRatio: diffRatio,
            geometryChanged: geometryChanged, tokenInvalidated: invalidated,
            noOpSuspected: noOp, elapsed: Date().timeIntervalSince(start))
    }

    /// 在截图坐标 (x, y) 点击。坐标以截图左上角为原点，单位是图像像素。
    public func clickAt(token: String, screenshotID: String, x: Double, y: Double) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(x, y, in: binding)
        try validateCoordinateWindow(binding, pid: r.pid)
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        try performCoordinate(token: token) {
            _ = try reader.clickAt(pid: r.pid, windowTitle: binding.windowTitle, x: point.x, y: point.y)
        }
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
    }

    /// 在截图坐标 (x, y) 滚动。dy > 0 表示向下，dx > 0 表示向右。
    public func scrollAt(
        token: String, screenshotID: String, x: Double, y: Double, dx: Double, dy: Double
    ) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(x, y, in: binding)
        guard abs(dx) + abs(dy) > 0 else {
            throw WireError.invalidCoordinates("滚动增量不能为 0。")
        }
        try validateCoordinateWindow(binding, pid: r.pid)
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        try performCoordinate(token: token) {
            _ = try reader.scrollAt(
                pid: r.pid, windowTitle: binding.windowTitle, x: point.x, y: point.y, dx: dx, dy: dy)
        }
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
    }

    /// 从截图坐标 (fromX, fromY) 拖到 (toX, toY)。
    public func drag(
        token: String, screenshotID: String,
        fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int
    ) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(fromX, fromY, in: binding)
        try checkPoint(toX, toY, in: binding)
        guard fromX != toX || fromY != toY else {
            throw WireError.invalidCoordinates("拖拽的起点与终点相同。")
        }
        try validateCoordinateWindow(binding, pid: r.pid)
        let start = Date()
        let from = globalPoint(x: fromX, y: fromY, binding: binding)
        let to = globalPoint(x: toX, y: toY, binding: binding)
        try performCoordinate(token: token) {
            _ = try reader.dragAt(
                pid: r.pid, windowTitle: binding.windowTitle,
                fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
                durationMs: max(100, min(2_000, durationMs)))
        }
        return observeCoordinate(token: token, r: r, snap: snap, binding: binding, start: start)
    }
}
