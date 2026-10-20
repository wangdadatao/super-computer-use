# 窗口列表与窗口根实测（TextEdit）

- 日期：2026-10-20
- 环境：macOS 14.4，Apple Silicon；`scu`/`scu-native` 由当前工作区构建（协议 v11）
- 目的：验证 `list_windows` 与 `get_ax_state(window=...)` 的窗口根是否在真实多窗口应用上成立，
  以及一个窗口的句柄动作是否会落到另一个窗口
- 目标：系统 TextEdit（`com.apple.TextEdit`），两个临时文档窗口 `/tmp/scu-win-a.txt`、`/tmp/scu-win-b.txt`

## 步骤与结果

1. 用 `open -a TextEdit /tmp/scu-win-a.txt /tmp/scu-win-b.txt` 打开两个窗口。
2. CLI `scu windows --pid 97863`：

   ```text
   "scu-win-a.txt"	(-2251,-220,656,422)
   "scu-win-b.txt"	(-2222,-191,656,422)
   ```

   两个窗口都列出；坐标为负，因为窗口在副屏。frame 与后续 AX 根窗口一致。

3. `scu dump --pid 97863 --window scu-win-a.txt --depth 2`：

   ```text
   [AXWindow] subrole=AXStandardWindow title="scu-win-a.txt" id="_NS:34"
     [AXScrollArea] id="_NS:8"
       [AXTextArea] id="First Text View" value="window A\n"
       ...
   ```

   根是 `AXWindow`，不是 `AXApplication`；树只包含该窗口。

4. 不存在的标题：

   ```text
   [window_not_found] 进程 97863 找不到标题为“not-here.txt”的窗口；请重新读取界面并选择仍存在的窗口。（retry=after_refresh）
   ```

   退出码 1；没有回退到应用根。

5. 通过 MCP stdio（`scu mcp --actions`）：

   - `list_windows(pid=97863)` 返回两行相同的标题/frame；
   - `get_ax_state(pid=97863, window="scu-win-b.txt", max_depth=1)` 的标题行含 `窗口="scu-win-b.txt"`，
     首行元素是 `[AXWindow#1] "scu-win-b.txt"`；
   - `get_ax_state(pid=97863, window="missing.txt")` 返回工具错误 `[window_not_found]`。

6. 跨窗口元素动作：

   - 读取 `scu-win-a.txt`，得到令牌 `s1akxmc.1`，`AXTextArea#3` 的 value 是 `"window A\n"`；
   - 用该令牌执行 `set_value(token, handle=3, value="WINDOW A ONLY\n")`：
     报告 `delivered=true observed=true converged=true treeChanged=true targetChanged=false noOpSuspected=false`；
   - 重新读两个窗口：
     - A：`AXTextArea#3 value="WINDOW A ONLY\n"`；
     - B：`AXTextArea#3 value="window B\n"`，没有被改。
   - 两个窗口的局部句柄相同（都是 `#3`），但令牌上的 `windowTitle` 使动作只落在 A。

## 结论

在 TextEdit 两个窗口上成立：

- `list_windows` 能枚举真实窗口的标题与 frame；
- `get_ax_state(window=...)` 的树根是目标 `AXWindow`；
- 窗口标题不存在时失败关闭，不退回应用根；
- 元素动作使用令牌上的窗口标题，同名局部句柄不会跨窗口误操作。

## 限定

- 只测了 TextEdit 一种应用；CEF/Electron 的窗口枚举与根行为未测。
- 没有测试同名窗口（两个窗口标题完全相同）；当前实现只取第一个，未构造该场景。
- 没有测试窗口改名后的动作；单元测试覆盖 `window_not_found`，真实改名路径未跑。
- 没有测试跨窗口拖拽/坐标动作；截图、坐标动作仍只按标题绑定。
- 修改了临时文件 A 的内存内容，没有保存；验证后退出 TextEdit 并删除临时文件。
