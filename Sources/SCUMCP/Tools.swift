import Foundation
import SCUCore
import SCUWire

/// 工具目录。只读档工具恒有；**会改变桌面状态的工具（`isAction`）只在启动时显式开启动作档才暴露**，
/// 未开启时它们不出现在 `tools/list`，调用也按未知工具处理。每个工具都带 `readOnlyHint` 如实声明；
/// `get_screenshot` 在只读档可用，但会激活窗口，不算严格只读。
// @project-doc docs/interfaces/mcp_surface.md#tool_catalog
enum ScuTool: String, CaseIterable {
    case checkPermissions = "check_permissions"
    case listApps = "list_apps"
    case listWindows = "list_windows"
    case getAXState = "get_ax_state"
    case getScreenshot = "get_screenshot"
    case launchApp = "launch_app"
    case click
    case clickAt = "click_at"
    case scrollAt = "scroll_at"
    case drag
    case typeText = "type_text"
    case pressKey = "press_key"
    case setValue = "set_value"

    var isAction: Bool {
        self != .checkPermissions && self != .listApps && self != .listWindows
            && self != .getAXState && self != .getScreenshot
    }

    /// MCP 的 `readOnlyHint`。`get_screenshot` 不修改应用内容，但会激活并 raise 目标窗口，
    /// 属于可见副作用，因此不声明为只读；它仍然在只读档可用（可用性由 `isAction` 决定）。
    var isReadOnly: Bool {
        switch self {
        case .getScreenshot: return false
        default: return !isAction
        }
    }

    static func available(actions: Bool) -> [ScuTool] {
        allCases.filter { actions || !$0.isAction }
    }
}
