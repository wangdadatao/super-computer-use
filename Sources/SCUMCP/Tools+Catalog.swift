import Foundation
import SCUCore
import SCUWire

extension ScuTool {
    var title: String {
        switch self {
        case .checkPermissions: return "检查辅助功能权限"
        case .listApps: return "列出应用"
        case .listWindows: return "列出窗口"
        case .getAXState: return "读取无障碍树（默认差异）"
        case .getScreenshot: return "截取窗口并叠加标签"
        case .launchApp: return "启动应用"
        case .click: return "点击元素"
        case .clickAt: return "按截图坐标点击"
        case .scrollAt: return "按截图坐标滚动"
        case .drag: return "按截图坐标拖拽"
        case .typeText: return "向元素输入文本"
        case .pressKey: return "向元素发送按键"
        case .setValue: return "直接写入元素的值"
        }
    }

    var description: String {
        switch self {
        case .checkPermissions:
            return """
                检查启动本服务的宿主应用是否已获得 macOS 辅助功能权限。只读。\
                权限归属于宿主应用（启动本服务的程序），不是整台机器；未授权时 get_ax_state 无法读取。
                """
        case .listApps:
            return """
                列出可读取的正在运行的应用，每行 pid、名称、bundle id（制表符分隔）。只读。\
                get_ax_state 需要这里的 pid。
                """
        case .listWindows:
            return """
                列出指定应用可枚举的窗口，每行标题与 frame（左上角原点）。只读。\
                标题是 get_ax_state 的 window、get_screenshot 的窗口绑定与坐标动作使用的标识；\
                同名窗口只选第一个；没有标题的窗口显示为 -。先用 list_apps 取得 pid。
                """
        case .getScreenshot:
            return """
                截取 get_ax_state 令牌对应的目标窗口，并在图上叠加可交互元素的短标签。\
                不修改应用内容，但截图前会激活并 raise 目标窗口（可能改变前台），需要屏幕录制权限。\
                返回 PNG 图像与 screenshot_id；图像坐标以窗口左上角为原点，`scale` 是图像像素 / 窗口点。\
                文本元素表仍是权威：徽标太小、重叠或被裁掉时，按 get_ax_state 的标签选择。\
                屏幕录制权限按宿主应用归属，未授予时返回 system_permission_missing。
                """
        case .scrollAt:
            return """
                在 get_screenshot 的截图坐标 (x, y) 投递滚轮事件。会改变应用的状态。\
                坐标以截图左上角为原点，单位是图像像素；必须给出令牌与 screenshot_id。\
                dy > 0 表示向下滚，dx > 0 表示向右滚；增量为 0 会被拒绝。\
                点击前会激活并 raise 目标窗口；滚动后重读 AX 树并比较全图像素比例。\
                返回 noOpSuspected=true 时不要反复滚；先用 get_screenshot 核实。
                """
        case .drag:
            return """
                在 get_screenshot 的截图坐标内从 (from_x, from_y) 拖到 (to_x, to_y)。\
                会移动真实光标并可能改变应用状态（移动文件/列表项/画布）。\
                坐标以截图左上角为原点；必须给出令牌与 screenshot_id；duration_ms 默认 400，范围 100...2000。\
                点击前会激活并 raise 目标窗口；拖拽后重读 AX 树并比较全图像素比例。\
                这是高风险动作：调用前应确认起点/终点，不要对不确定的界面拖拽。
                """
        case .launchApp:
            return """
                启动（或激活）一个应用。identifier 可以是 bundle id、显示名或 .app 路径。\
                启动前会解析 bundle id 并检查拒绝类目；终端、脚本运行器、密码管理器、系统设置等会被拒绝。\
                已在运行的应用会被激活而不是重复启动。启动后会等待 10 秒确认进程出现。\
                这是会改变桌面状态的动作；启动成功后用 list_apps 或 get_ax_state 继续。
                """
        case .clickAt:
            return """
                在 get_screenshot 的截图坐标 (x, y) 投递一次鼠标左键点击。会改变应用的状态。\
                坐标以截图左上角为原点，单位是图像像素；必须同时给出令牌与 screenshot_id。\
                点击前会核对截图属于该令牌、窗口位置/缩放未变；坐标越界返回 invalid_coordinates。\
                返回的是**观察到的效果**：点击后重读 AX 树，报告结构是否变化。\
                坐标点击可能只改变像素而不改 AX 树，这时会报 noOpSuspected=true；\
                请用 get_screenshot 核实，不要反复点。屏幕保护/遮挡等情况下可能点到别处，\
                调用前应确认目标窗口可见且在前台。
                """
        case .click:
            return """
                点击元素：对 get_ax_state 输出里的某个句柄执行 AXPress（无障碍的"按下"，不移动真实鼠标）。会改变应用的状态。\
                必须给出该输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效（界面结构变了）、目标已不是读取时的那个、\
                或应用属于拒绝类目（终端、脚本运行器、密码管理器、系统设置、Cursor 等）时，动作不会执行，并返回分类的错误。\
                返回的是**观察到的效果**，不是"成功"的保证：已投递只表示系统没有报错；\
                之后会重读界面直到稳定（最多约 3 秒），报告结构是否变化。\
                "疑似空操作"表示界面稳定后结构没有任何变化，请核实后再继续。\
                结构变化时旧令牌作废，需重新 get_ax_state。不支持 AXPress 的元素返回 unsupported_operation。
                """
        case .typeText:
            return """
                把文本逐字输入到指定元素：先 raise 它所在的窗口并聚焦，再向目标进程投递按键事件。\
                会改变应用的状态，并可能把目标应用切到前台（键盘事件由 key window 接收）。\
                必须给出 get_ax_state 输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效、目标已不是读取时的那个、\
                或应用属于拒绝类目时不会执行，并返回分类的错误。\
                输入经过应用的按键处理（与"设值"不同），可以触发自动完成、实时校验与回车等行为。\
                文本里的换行与制表符分别按 Return 与 Tab 投递。\
                返回的是**观察到的效果**，不是"成功"的保证：之后会重读界面直到稳定，报告结构是否变化；\
                结构变化时旧令牌作废，需重新 get_ax_state。
                """
        case .pressKey:
            return """
                向指定元素发送一个按键或组合键：先 raise 它所在的窗口并聚焦，再发键。\
                如 Return、Tab、esc、cmd+c、shift+左方向键；可能把目标应用切到前台。\
                键名用 + 分隔，修饰键顺序无关；不认识键名会拒绝，不猜测。会改变应用的状态。\
                必须给出 get_ax_state 输出的令牌，并用句柄或标签指定目标（二者二选一）；令牌失效、目标对不上或应用属于拒绝类目时不会执行。\
                返回的是**观察到的效果**，不是"成功"的保证；结构变化时旧令牌作废。
                """
        case .setValue:
            return """
                直接把值写入指定元素（无障碍设值）。会改变应用的状态。\
                这是默认的写入路径：不经过键盘与输入法，速度快、不触发按键处理；\
                因此也不会触发自动完成、实时校验这类"输入过程中"的行为。\
                只有元素声明了可写的 AXValue 时才执行；不支持时返回 unsupported_operation，\
                不会自动改成逐字输入（两者的副作用不同）。必须给出令牌，并用句柄或标签指定目标（二者二选一）；\
                值变化后令牌作废，需要重新 get_ax_state。
                """
        case .getAXState:
            return """
                读取指定应用的无障碍树，返回文本化元素表。只读，不会操作应用。\
                默认返回与上一次读取的差异（~ 变化，+ 新增，删除项用旧句柄范围概括）；\
                首次读取、切换目标、树被截断或读取参数变化时返回完整表。需要完整表时传 full=true。\
                可用 window 指定窗口标题：此时元素表以该窗口为根读取，截图与坐标动作也绑定该窗口。\
                窗口标题来自 list_windows；找不到会返回 window_not_found。\
                每行一个元素，缩进表示层级，格式 [a] [角色#句柄] "标题" 属性… frame=(x,y,w,h)。\
                可交互元素前的 [a] 是本次快照的标签；click / type_text / press_key / set_value 可以用 label 代替 handle。\
                输出带一个令牌，句柄与令牌配对、只在该令牌有效期内可用（界面结构变化后令牌失效）；click / type_text / press_key / set_value（仅动作档提供）接受它们。\
                读取有总时间预算，耗尽时输出会明确标注"已截断"。\
                元素多于 max_elements 时按层级优先显示（先看整体结构，不是先序的前 N 个），\
                被折叠的元素行尾标 (折叠 N)，表示其下还有 N 个后代未显示。\
                要看某一部分，用 focus（按标题、描述、值或标识符的子串匹配）和/或 focus_role（角色）：\
                只展开匹配的子树，并在前面用 "@ 祖先链" 说明它在哪里。\
                推荐流程：先不带 focus 看概览，再用 focus 逐块展开。\
                Electron/Chromium 应用的树大小可能随读取时机变化（原因未确定），读到的树明显偏小时可稍后重读。\
                先用 list_apps 取得 pid。
                """
        }
    }
}
