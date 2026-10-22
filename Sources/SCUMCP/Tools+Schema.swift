import Foundation
import SCUCore
import SCUWire

extension ScuTool {
    var inputSchema: JSONValue {
        switch self {
        case .checkPermissions, .listApps:
            return ["type": "object", "properties": [:], "additionalProperties": false]
        case .listWindows:
            return [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "目标应用的进程 id，来自 list_apps"]
                ],
                "required": ["pid"],
                "additionalProperties": false,
            ]
        case .getScreenshot:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"]
                ],
                "required": ["token"],
                "additionalProperties": false,
            ]
        case .launchApp:
            return [
                "type": "object",
                "properties": [
                    "app": ["type": "string", "description": "bundle id、显示名或 .app 路径"]
                ],
                "required": ["app"],
                "additionalProperties": false,
            ]
        case .clickAt:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "x": ["type": "integer", "minimum": 0, "description": "截图内的 x 像素（左上角原点）"],
                    "y": ["type": "integer", "minimum": 0, "description": "截图内的 y 像素（左上角原点）"],
                ],
                "required": ["token", "screenshot_id", "x", "y"],
                "additionalProperties": false,
            ]
        case .scrollAt:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "x": ["type": "integer", "minimum": 0, "description": "滚动位置 x（截图像素）"],
                    "y": ["type": "integer", "minimum": 0, "description": "滚动位置 y（截图像素）"],
                    "dx": ["type": "integer", "description": "水平增量；正数向右，默认 0"],
                    "dy": ["type": "integer", "description": "垂直增量；正数向下"],
                ],
                "required": ["token", "screenshot_id", "x", "y", "dy"],
                "additionalProperties": false,
            ]
        case .drag:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "screenshot_id": ["type": "string", "description": "get_screenshot 返回的 screenshot_id"],
                    "from_x": ["type": "integer", "minimum": 0, "description": "起点 x（截图像素）"],
                    "from_y": ["type": "integer", "minimum": 0, "description": "起点 y（截图像素）"],
                    "to_x": ["type": "integer", "minimum": 0, "description": "终点 x（截图像素）"],
                    "to_y": ["type": "integer", "minimum": 0, "description": "终点 y（截图像素）"],
                    "duration_ms": ["type": "integer", "minimum": 100, "maximum": 2000, "description": "拖拽时长，默认 400"],
                ],
                "required": ["token", "screenshot_id", "from_x", "from_y", "to_x", "to_y"],
                "additionalProperties": false,
            ]
        case .click:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": [
                        "type": "integer", "minimum": 1, "description": "该输出元素表里的句柄编号（[角色#句柄] 的数字）；与 label 二选一",
                    ],
                    "label": ["type": "string", "description": "该输出元素表里的短标签（[a] 的字母）；与 handle 二选一"],
                ],
                "required": ["token"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .typeText:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "要输入到的元素句柄；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "text": [
                        "type": "string", "minLength": 1, "maxLength": .int(scuMaxInputTextLength),
                        "description": "要输入的文本",
                    ],
                ],
                "required": ["token", "text"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .pressKey:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "接收按键的元素句柄（会先聚焦它）；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "key": [
                        "type": "string", "minLength": 1,
                        "description": "按键或组合键，如 Return、Tab、esc、cmd+c；修饰键可用 cmd/shift/alt/ctrl",
                    ],
                ],
                "required": ["token", "key"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .setValue:
            return [
                "type": "object",
                "properties": [
                    "token": ["type": "string", "description": "get_ax_state 标题行里的令牌"],
                    "handle": ["type": "integer", "minimum": 1, "description": "要写入的元素句柄；与 label 二选一"],
                    "label": ["type": "string", "description": "该输出元素表里的短标签；与 handle 二选一"],
                    "value": ["type": "string", "maxLength": .int(scuMaxInputTextLength), "description": "要写入的值"],
                ],
                "required": ["token", "value"],
                "anyOf": [["required": ["handle"]], ["required": ["label"]]],
                "additionalProperties": false,
            ]
        case .getAXState:
            return [
                "type": "object",
                "properties": [
                    "pid": ["type": "integer", "description": "目标应用的进程 id，来自 list_apps"],
                    "max_depth": [
                        "type": "integer", "minimum": 0, "maximum": .int(scuMaxTreeDepth),
                        "description": .string("读取深度上限，默认 \(Self.defaultDepth)"),
                    ],
                    "budget_ms": [
                        "type": "integer", "minimum": .int(scuTreeBudgetMsRange.lowerBound),
                        "maximum": .int(scuTreeBudgetMsRange.upperBound),
                        "description": .string("读取的总时间预算（毫秒），默认 \(scuDefaultTreeBudgetMs)"),
                    ],
                    "focus": [
                        "type": "string",
                        "description": "只显示匹配的子树：与标题、描述、值、标识符做不区分大小写的子串匹配。可与 focus_role 同时给出（需同时满足）",
                    ],
                    "focus_role": [
                        "type": "string",
                        "description": "只显示该角色的子树，如 AXButton 或 Button（等价）",
                    ],
                    "max_elements": [
                        "type": "integer", "minimum": .int(ElementTable.maxElementsRange.lowerBound),
                        "maximum": .int(ElementTable.maxElementsRange.upperBound),
                        "description": .string("最多输出的元素数，默认 \(ElementTable.defaultMaxElements)"),
                    ],
                    "window": [
                        "type": "string",
                        "description": "窗口标题；元素表以该窗口为根读取，截图与坐标动作也绑定该窗口",
                    ],
                    "full": [
                        "type": "boolean",
                        "description": "返回完整元素表，而不是与上次读取的差异；差异过大时也会自动回退完整表",
                    ],
                ],
                "required": ["pid"],
                "additionalProperties": false,
            ]
        }
    }

    var definition: JSONValue {
        [
            "name": .string(rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(isReadOnly),
                "destructiveHint": .bool(isAction),
                "idempotentHint": .bool(isReadOnly),
                "openWorldHint": .bool(isAction),
            ],
        ]
    }

    static let defaultDepth = scuDefaultTreeDepth
}
