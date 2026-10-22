import AppKit
import ApplicationServices
import SCUWire

/// 输入与按键（v1 第一项，见 ADR-0016）。
///
/// 两条路径都要求**显式的元素定位器**：先沿路径核对并聚焦该元素，再把事件投递到目标进程。
/// 不使用"当前焦点"作为隐式目标——写错位置可能触发提交或发送，代价不可逆
/// （edit_semantics.md「写入的目标解析」）。
///
/// 事件用 `CGEvent.postToPid` 直接投递给目标进程，不激活应用、不移动鼠标、不抢前台。
/// 每个按键都是 down + up，不在动作之间保持按住状态（v1 不支持长按）。
// @project-doc docs/decisions/adr_0016_input_and_keys.md#input_decision
extension AXBackend {
    /// 一次按键：虚拟键码 + 修饰键。
    struct KeyCombo: Equatable {
        var code: CGKeyCode
        var flags: CGEventFlags
    }

    // MARK: - 入口

    /// 逐字输入文本。换行与制表符分别映射为 Return 与 Tab，其余字符按 Unicode 字符串投递。
    public static func typeText(
        pid: Int32, windowTitle: String? = nil, locator: ElementLocator, text: String
    ) throws -> ActionResult {
        guard !text.isEmpty else { throw WireError.unsupportedOperation("文本为空") }
        guard text.count <= inputTextLimit else {
            throw WireError.internalError("文本过长：\(text.count) 个字符，上限 \(inputTextLimit)")
        }
        switch try locateTarget(pid: pid, windowTitle: windowTitle, locator: locator) {
        case .stale(let detail):
            return .stale(detail)
        case .found(let element):
            prepareKeyboardTarget(element, pid: pid)
            try focus(element, pid: pid)
            let source = CGEventSource(stateID: .combinedSessionState)
            for character in text {
                switch character {
                case "\n", "\r":
                    postKey(KeyCombo(code: keyCodes["return"]!, flags: []), pid: pid, source: source)
                case "\t":
                    postKey(KeyCombo(code: keyCodes["tab"]!, flags: []), pid: pid, source: source)
                default:
                    postUnicode(String(character), pid: pid, source: source)
                }
                Thread.sleep(forTimeInterval: Double(scuInputPerCharacterMs) / 1000)
            }
            return .acted
        }
    }

    /// 发送一个按键或组合键。键名与修饰键的解析见 `parseKey`。
    public static func pressKey(
        pid: Int32, windowTitle: String? = nil, locator: ElementLocator, key: String
    ) throws -> ActionResult {
        let combo = try parseKey(key)
        switch try locateTarget(pid: pid, windowTitle: windowTitle, locator: locator) {
        case .stale(let detail):
            return .stale(detail)
        case .found(let element):
            prepareKeyboardTarget(element, pid: pid)
            try focus(element, pid: pid)
            postKey(combo, pid: pid, source: CGEventSource(stateID: .combinedSessionState))
            return .acted
        }
    }

    /// 通过无障碍接口直接写元素的值。**要求元素声明 AXValue 可写**，否则拒绝——
    /// 不自动回退到逐字输入：两者的副作用不同（edit_semantics.md）。
    public static func setValue(
        pid: Int32, windowTitle: String? = nil, locator: ElementLocator, value: String
    ) throws -> ActionResult {
        guard value.count <= inputTextLimit else {
            throw WireError.internalError("值过长：\(value.count) 个字符，上限 \(inputTextLimit)")
        }
        switch try locateTarget(pid: pid, windowTitle: windowTitle, locator: locator) {
        case .stale(let detail):
            return .stale(detail)
        case .found(let element):
            var settable = DarwinBoolean(false)
            let query = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
            guard query == .success, settable.boolValue else {
                throw WireError.unsupportedOperation("元素的 AXValue 不可写，不能设值")
            }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            switch status {
            case .success:
                return .acted
            case .attributeUnsupported, .notImplemented, .actionUnsupported:
                throw WireError.unsupportedOperation("设值失败：\(axErrorName(status))")
            default:
                throw WireError.actionFailed("设值失败：\(axErrorName(status))")
            }
        }
    }

    // MARK: - 定位与聚焦

    /// 定位目标并检查可访问性。返回 `.stale` 时不执行任何动作。
    static func locateTarget(
        pid: Int32, windowTitle: String? = nil, locator: ElementLocator
    ) throws -> LocateResult<AXUIElement> {
        try locateInApp(pid: pid, windowTitle: windowTitle, locator: locator)
    }

    /// 键盘事件按进程投递，但真正接收文字的是**该进程当前 key window 的 first responder**。
    /// 多窗口时只设 AXFocused 不够：目标窗口不是 key 时，输入会落到另一个窗口。
    /// 因此先把目标元素所在的窗口 raise 成 key，再激活应用；失败只记录为平台事实，
    /// 仍继续投递（部分应用不要求前台）。
    static func prepareKeyboardTarget(_ element: AXUIElement, pid: Int32) {
        if let window = enclosingWindow(of: element) {
            if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
                _ = app.activate(options: [.activateAllWindows])
                for _ in 0..<10 {
                    if app.isActive { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        } else if let app = NSRunningApplication(processIdentifier: pid), !app.isActive {
            _ = app.activate(options: [.activateAllWindows])
        }
    }

    /// 从元素沿 AXParent 向上找窗口。找不到时返回 nil（菜单项等没有窗口祖先）。
    static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current = element
        for _ in 0..<32 {
            if string(current, kAXRoleAttribute) == kAXWindowRole { return current }
            guard let parent = copy(current, kAXParentAttribute),
                CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = parent as! AXUIElement
            AXUIElementSetMessagingTimeout(current, messagingTimeout)
        }
        return nil
    }

    /// 应用当前的 first responder。用于避免对已聚焦元素重复设焦点（会折叠选区）。
    static func focusedElement(pid: Int32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let value = copy(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// 把焦点设到目标元素。焦点是异步生效的，等它被读回为 true 最多约 300 毫秒；
    /// 元素不报告焦点状态时不视为失败（部分控件不支持 AXFocused 的读取）。
    static func focus(_ element: AXUIElement, pid: Int32) throws {
        // 已是焦点时不要重复 SetAttribute：TextEdit 等控件会在重设焦点时把选区折叠成插入点，
        // 从而破坏前一个 press_key(cmd+a) 建立的全选状态。
        // 不能用元素的 AXFocused 判断：TextEdit 的 AXTextArea 在成为 first responder 后仍可能报 false。
        if let focused = focusedElement(pid: pid), CFEqual(focused, element) { return }
        let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        switch status {
        case .success:
            break
        case .attributeUnsupported, .notImplemented, .actionUnsupported:
            throw WireError.unsupportedOperation("元素不接受焦点（\(axErrorName(status))）")
        default:
            throw WireError.actionFailed("设置焦点失败：\(axErrorName(status))")
        }
        for _ in 0..<6 {
            if bool(element, kAXFocusedAttribute) == true { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - 事件投递

    static let inputTextLimit = scuMaxInputTextLength

    static func postKey(_ combo: KeyCombo, pid: Int32, source: CGEventSource?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.code, keyDown: down) else {
                continue
            }
            event.flags = combo.flags
            event.postToPid(pid)
        }
    }

    static func postUnicode(_ text: String, pid: Int32, source: CGEventSource?) {
        var utf16 = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.postToPid(pid)
        }
    }

    // MARK: - 键名解析

    /// 解析 `cmd+shift+t` 这类组合键。修饰键顺序无关；只允许一个主键。
    /// 未知键名或缺少主键时抛 `unsupported_operation`，不猜测。
    static func parseKey(_ raw: String) throws -> KeyCombo {
        let parts = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !parts.isEmpty, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw WireError.unsupportedOperation("键名为空")
        }
        var flags: CGEventFlags = []
        var main: String?
        var extraShift = false
        for part in parts {
            switch part {
            case "cmd", "command", "super", "meta":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "alt", "option", "opt":
                flags.insert(.maskAlternate)
            case "ctrl", "control":
                flags.insert(.maskControl)
            default:
                guard main == nil else {
                    throw WireError.unsupportedOperation("组合键里有多个主键：\(raw)")
                }
                main = part
            }
        }
        guard let name = main, let code = keyCodes[name] else {
            throw WireError.unsupportedOperation("不认识的键：\(raw)")
        }
        // 需要 Shift 才能输入的符号（如 "plus"）自动带上 Shift。
        if shiftedKeys.contains(name) { extraShift = true }
        if extraShift { flags.insert(.maskShift) }
        return KeyCombo(code: code, flags: flags)
    }

    /// US 布局的虚拟键码。只覆盖常用键；未列出的键返回"不认识"而不是猜。
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "spacebar": 49,
        "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "plus": 24, "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44,
        "semicolon": 41, "quote": 39, "backslash": 42, "leftbracket": 33, "rightbracket": 30,
        "grave": 50,
    ]

    /// 需要 Shift 的符号别名。
    static let shiftedKeys: Set<String> = ["plus"]
}
