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
        let capture = try reader.captureWindow(target: r.target)
        // 绑定**实际被截到的窗口**。令牌没有指定窗口时，原生层会选最大窗口；
        // 若这里仍存令牌的 nil，后续坐标动作会重新选一次，可能落到另一个窗口。
        let boundWindowID = capture.windowID ?? r.windowID
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
            token: token, windowID: boundWindowID, windowTitle: boundWindowTitle,
            windowFrame: capture.windowFrame, scale: capture.scale, width: capture.width,
            height: capture.height, png: capture.png)
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
    /// 返回这一次的截图：它发生在最后一次激活之后，可以当像素基线用。
    @discardableResult
    func validateCoordinateWindow(_ binding: ScreenshotBinding, pid: Int32) throws -> WindowCapture {
        let target = Target.forWindow(pid: pid, windowID: binding.windowID, titleHint: binding.windowTitle)
        let current = try reader.captureWindow(target: target)
        guard current.windowFrame == binding.windowFrame, current.scale == binding.scale,
            current.width == binding.width, current.height == binding.height,
            binding.windowID == nil || current.windowID == binding.windowID
        else {
            throw WireError.staleGeometry("截图后窗口位置/缩放已变化，请重新 get_screenshot。")
        }
        return current
    }

    /// 坐标动作的前置基线，必须在**最后一次激活之后、投递之前**采集（A2）。
    ///
    /// 坐标动作链里有三次激活（截图、几何复核、投递前）；截图与复核都会 activate/raise 目标窗口，
    /// 而激活本身会改动 AX 树与窗口外观。若基线取在激活之前，那些变化会被算成“点击的效果”，
    /// 于是点空白也报 changed。这里在几何复核（最后一次激活）之后重读一次，再开始计时。
    struct CoordinateBaseline {
        var entries: [ElementTable.Entry]
        /// 绑定窗口的子树的摘要；定位不到窗口时为 nil（未知，不当作“没变化”）。
        var digest: Int?
        var truncated: Bool
        /// 激活后的窗口图，用作像素基线与光标形态判定。
        var png: Data
    }

    func coordinateBaseline(
        r: Record, snap: Snapshot, binding: ScreenshotBinding, capture: WindowCapture
    ) -> CoordinateBaseline {
        guard
            let reading = try? reader.readTree(
                target: r.target, maxDepth: snap.maxDepth, budgetMs: snap.budgetMs)
        else {
            return CoordinateBaseline(entries: [], digest: nil, truncated: true, png: capture.png)
        }
        let entries = ElementTable.flatten(reading.root)
        return CoordinateBaseline(
            entries: entries,
            digest: reading.truncated ? nil : Self.windowScopedDigest(entries, binding: binding),
            truncated: reading.truncated, png: capture.png)
    }

    /// 落点是否落在文本类元素上。只用来决定“要不要看插入光标”，不参与“命中”判定。
    static let textRoles = scuTextRoles

    static func pointIsInTextElement(
        _ entries: [ElementTable.Entry], x: Double, y: Double
    ) -> Bool {
        entries.contains { entry in
            guard textRoles.contains(entry.node.role), let f = entry.node.frame,
                f.width > 0, f.height > 0
            else { return false }
            return x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height
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
    @discardableResult
    func performCoordinate<T>(
        token: String, _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
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
        ScreenshotMapping(windowFrame: binding.windowFrame, scale: binding.scale)
            .globalPoint(imageX: x, imageY: y)
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
        // AXNode 没有窗口号；优先用截图 frame，标题兜底。窗口 ID 已保证截图/动作
        // 选的是同一个窗口，这里只负责把效果比较限定到它的子树。
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
        token: String, r: Record, snap: Snapshot, binding: ScreenshotBinding,
        baseline: CoordinateBaseline, point: (x: Double, y: Double)?,
        probe: ClickProbe? = nil, start: Date
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
                windowID: r.windowID, windowTitle: r.windowTitle)
            observed = true
            invalidated = after.token != SnapshotToken(token)
            let afterEntries = ElementTable.flatten(after.reading.root)
            // 基线读不到（readTree 抛错或 truncated）就是 unknown，`treeChanged` 留 nil；
            // 不得退回激活前的令牌快照——那是早于最后一次激活的状态，激活本身的变化会被
            // 算成点击效果，等于把 A2 修掉的老 bug 从降级路径放回来。也不得用“令牌失效”
            // 顶替结构变化：激活改过树同样会让令牌失效。
            let beforeDigest = baseline.truncated ? nil : baseline.digest
            if let before = beforeDigest,
                let afterDigest = Self.windowScopedDigest(afterEntries, binding: binding)
            {
                changed = before != afterDigest
            }
        } catch {
            observed = false
        }

        var screenshotChanged: Bool?
        var diffRatio: Double?
        var geometryChanged = false
        var verified = false
        var verifiedBy: String?
        var verifiedNote: String?
        // 判据按落点类型二选一，不叠加：文本落点只看同一元素的 AXSelectedTextRange，
        // 非文本落点才看像素。两条都跑再 OR，会让“文本上像素判据失效”被永久掩盖。
        let landedOnText = probe?.rangeBefore != nil
        if let probe, let before = probe.rangeBefore {
            if !probe.elementValid {
                verifiedNote =
                    probe.note ?? "落点元素的 AX 引用在点击后失效，无法比较选区；不回退到像素判据。"
            } else if let after = probe.rangeAfter {
                if after != before {
                    verified = true
                    verifiedBy = "selection_changed"
                } else {
                    verifiedNote = "点击后同一元素的选区没有变化（\(before)）。"
                }
            } else {
                verifiedNote =
                    probe.note ?? "点击后读不到同一元素的 AXSelectedTextRange，无法确认选区变化。"
            }
        } else if let probe, let note = probe.note {
            // 没进选区判据的原因照实报（例如“落点不在文本控件内”），好核对走了哪条判据。
            verifiedNote = note
        }
        let boundTarget = Target.forWindow(pid: r.pid, windowID: binding.windowID, titleHint: binding.windowTitle)
        if let after = try? reader.captureWindow(target: boundTarget) {
            if after.width != binding.width || after.height != binding.height
                || after.windowFrame != binding.windowFrame || after.scale != binding.scale
                || (binding.windowID != nil && after.windowID != binding.windowID)
            {
                geometryChanged = true
            } else if let ratio = ScreenshotDiff.changedRatio(before: baseline.png, after: after.png) {
                diffRatio = ratio
                screenshotChanged = ratio > 0.001
                // 非文本落点才看像素：落点所在行出现了插入光标形态的窄高像素变化。
                // 文本落点已经由选区判定（上面）；这里必须跳过，避免两套判据叠加。
                // 插入光标会闪烁；一次抓图可能正好落在“灭”的相位。落点在文本上时
                // 最多再补拍两次（间隔 0.45 秒），看到任一帧有光标形态就算观察到。
                let global =
                    point.map {
                        ScreenshotMapping(windowFrame: binding.windowFrame, scale: binding.scale)
                            .globalPoint(imageX: $0.x, imageY: $0.y)
                    }
                if !landedOnText, let point, let global,
                    Self.pointIsInTextElement(baseline.entries, x: global.x, y: global.y)
                {
                    var sawCaret =
                        ScreenshotDiff.caretAppeared(
                            before: baseline.png, after: after.png, at: point, scale: binding.scale)
                        == true
                    var extra = 0
                    while !sawCaret, extra < 2 {
                        usleep(450_000)
                        extra += 1
                        guard let again = try? reader.captureWindow(target: boundTarget),
                            again.width == after.width, again.height == after.height,
                            again.windowFrame == after.windowFrame
                        else { continue }
                        if ScreenshotDiff.caretAppeared(
                            before: baseline.png, after: again.png, at: point, scale: binding.scale)
                            == true
                        {
                            sawCaret = true
                        }
                    }
                    if sawCaret {
                        verified = true
                        verifiedBy = "caret_pixels"
                    }
                }
            }
        }

        let noOp = observed && changed == false && (screenshotChanged == false || screenshotChanged == nil)
        return CoordinateReport(
            pid: r.pid, delivered: true, verified: verified, verifiedBy: verifiedBy,
            landingRole: probe?.role, selectionBefore: probe?.rangeBefore,
            selectionAfter: probe?.rangeAfter, landingElementValid: probe?.elementValid,
            clickCount: probe?.clickCount, verifiedNote: verifiedNote,
            observed: observed, treeChanged: changed,
            screenshotChanged: screenshotChanged, diffRatio: diffRatio,
            geometryChanged: geometryChanged, tokenInvalidated: invalidated,
            noOpSuspected: noOp, elapsed: Date().timeIntervalSince(start))
    }

    /// 在截图坐标 (x, y) 点击。坐标以截图左上角为原点，单位是图像像素。
    public func clickAt(token: String, screenshotID: String, x: Double, y: Double) throws -> CoordinateReport {
        let (r, snap, binding) = try coordinateContext(token: token, screenshotID: screenshotID)
        try checkPoint(x, y, in: binding)
        let capture = try validateCoordinateWindow(binding, pid: r.pid)
        // A2：基线在最后一次激活之后、投递之前采集；start 也从这里计。
        let baseline = coordinateBaseline(r: r, snap: snap, binding: binding, capture: capture)
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        let boundTarget = Target.forWindow(pid: r.pid, windowID: binding.windowID, titleHint: binding.windowTitle)
        let probe = try performCoordinate(token: token) {
            try reader.clickAt(target: boundTarget, x: point.x, y: point.y)
        }
        return observeCoordinate(
            token: token, r: r, snap: snap, binding: binding, baseline: baseline,
            point: (x: x, y: y), probe: probe, start: start)
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
        let capture = try validateCoordinateWindow(binding, pid: r.pid)
        let baseline = coordinateBaseline(r: r, snap: snap, binding: binding, capture: capture)
        let start = Date()
        let point = globalPoint(x: x, y: y, binding: binding)
        let boundTarget = Target.forWindow(pid: r.pid, windowID: binding.windowID, titleHint: binding.windowTitle)
        try performCoordinate(token: token) {
            _ = try reader.scrollAt(
                target: boundTarget, x: point.x, y: point.y, dx: dx, dy: dy)
        }
        // 滚动没有可读的后置条件（没有光标/焦点），verified 保持 false，报告明写“是否命中未验证”。
        return observeCoordinate(
            token: token, r: r, snap: snap, binding: binding, baseline: baseline,
            point: nil, start: start)
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
        let capture = try validateCoordinateWindow(binding, pid: r.pid)
        let baseline = coordinateBaseline(r: r, snap: snap, binding: binding, capture: capture)
        let start = Date()
        let from = globalPoint(x: fromX, y: fromY, binding: binding)
        let to = globalPoint(x: toX, y: toY, binding: binding)
        let boundTarget = Target.forWindow(pid: r.pid, windowID: binding.windowID, titleHint: binding.windowTitle)
        try performCoordinate(token: token) {
            _ = try reader.dragAt(
                target: boundTarget, fromX: from.x, fromY: from.y, toX: to.x, toY: to.y,
                durationMs: max(100, min(2_000, durationMs)))
        }
        // 拖拽同样没有可读的后置条件；verified 保持 false。
        return observeCoordinate(
            token: token, r: r, snap: snap, binding: binding, baseline: baseline,
            point: nil, start: start)
    }
}
