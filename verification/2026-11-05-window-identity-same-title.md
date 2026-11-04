# 2026-11-05 同标题窗口身份回归（TextEdit）

**结论：R8 通过。四项判定全部 PASS。**

只做验证，未改 `Sources/`，未 build，未 commit/tag。

## 环境

| 项 | 值 |
| --- | --- |
| macOS | 26.6.2（Build 25G83），arm64 |
| 仓库 | `/Users/dager/aiwork/SuperComputerUse`，`main` @ `d107c07`（`v0.4.0-13-gd107c07`） |
| 二进制 | `.build/debug/scu`（2026-11-04 10:19），`scu 0.5.0` |
| 系统语言 | `zh-Hans-CN` |

## 目标窗口

为制造两个**标题完全相同**的窗口，且不触碰用户已开的文稿：

- 用户原有 TextEdit 实例 `pid 55304` 保持不动（它当时只有一个“打开”对话框窗口 `#3132906`，全程未操作）；
- 新建独立实例：
  ```bash
  mkdir -p /tmp/scu-r8-a /tmp/scu-r8-b
  printf 'R8 window A\n' > /tmp/scu-r8-a/scu-r8.txt
  printf 'R8 window B\n' > /tmp/scu-r8-b/scu-r8.txt
  open -na TextEdit /tmp/scu-r8-a/scu-r8.txt /tmp/scu-r8-b/scu-r8.txt
  ```
- 新实例 `pid 94725`，两个窗口标题都是 `scu-r8.txt`（标题取自文件名，未硬编码系统语言下的“未命名”）。

## 判定 1：两个窗口 ID 不同 — PASS

```bash
$ ./build/debug/scu windows --pid 94725
#3134009	"scu-r8.txt"	(214,112,656,422)
#3134010	"scu-r8.txt"	(185,83,656,422)
```

两行标题相同，`#windowID` 分别为 `3134009`、`3134010`，均非 nil、互不相同。frame 也不同。

MCP `list_windows(pid=94725)` 返回同样两行（同一组 ID），无重复、无 nil：

```text
#3134009	"scu-r8.txt"	(214,112,656,422)
#3134010	"scu-r8.txt"	(185,83,656,422)
```

## 判定 2：`dump --window-id` 命中各自窗口 — PASS

```bash
$ ./.build/debug/scu dump --pid 94725 --window-id 3134009 --depth 4
[AXWindow] subrole=AXStandardWindow title="scu-r8.txt" id="_NS:34"
  [AXScrollArea] id="_NS:8"
    [AXTextArea] id="First Text View" value="R8 window B\n"
    ...

$ ./.build/debug/scu dump --pid 94725 --window-id 3134010 --depth 4
[AXWindow] subrole=AXStandardWindow title="scu-r8.txt" id="_NS:34"
  [AXScrollArea] id="_NS:8"
    [AXTextArea] id="First Text View" value="R8 window A\n"
    ...
```

两个 ID 读到的是不同文本（B / A），树根都是目标 `AXWindow`，不是应用根。

为排除“内容不同只是碰巧读到另一个窗口”的循环论证，用单窗口截屏独立核对 windowID 与内容：

```bash
$ screencapture -x -o -l 3134009 /tmp/scu-r8-win-3134009-before.png
$ screencapture -x -o -l 3134010 /tmp/scu-r8-win-3134010-before.png
```

- `3134009` 截图正文为 `R8 window B`；
- `3134010` 截图正文为 `R8 window A`。

与两次 `dump` 的内容逐字一致。窗口与文件的对应按文件初始内容判定，未直接读取 `AXDocument`。

## 判定 3：`get_screenshot` 返回的 `window_id` 与请求一致 — PASS

MCP 会话（`scu mcp --actions --allow-app com.apple.TextEdit`）：

```text
$ get_ax_state(pid=94725, window_id=3134009, max_depth=4)
# pid=94725 令牌 ssow8j.1 元素 13 window_id=3134009 ...
[AXWindow#1] "scu-r8.txt" subrole=AXStandardWindow id="_NS:34" frame=(214,112,656,422)
  [a] [AXTextArea#3] value="R8 window B\n" ... frame=(214,144,656,384)

$ type_text(token="ssow8j.1", handle=3, text="SCU-ONLY-WINDOW-1")
已对 AXTextArea#3（pid 94725）投递输入。
effect: delivered=true observed=true converged=true treeChanged=true targetChanged=true noOpSuspected=false polls=2 elapsed=0.4s

$ get_ax_state(pid=94725, window_id=3134010, max_depth=4)
# pid=94725 令牌 ssow8j.2 元素 13 window_id=3134010 ...
[AXWindow#1] "scu-r8.txt" subrole=AXStandardWindow id="_NS:34" frame=(185,83,656,422)
  [a] [AXTextArea#3] value="R8 window A\n" ... frame=(185,115,656,384)

$ get_screenshot(token="ssow8j.2")
screenshot_id=gsow8j.1 图像 1312x844 scale=2.000 window=(185,83,656,422) window_id=3134010 title="scu-r8.txt"
```

返回 `window_id=3134010`，与请求的 id2 相同；`window=(185,83,656,422)` 与 `scu windows` 中 `#3134010` 的 frame 相同。截图正文为 `R8 window A`，不含 marker。

## 判定 4：marker 不串窗 — PASS

```bash
$ ./.build/debug/scu dump --pid 94725 --window-id 3134009 --depth 6 | grep -c 'SCU-ONLY-WINDOW-1'
1

$ ./.build/debug/scu dump --pid 94725 --window-id 3134010 --depth 6 | grep -c 'SCU-ONLY-WINDOW-1'
0
```

id1 的文本框为 `"SCU-ONLY-WINDOW-1R8 window B\n"`，id2 仍为 `"R8 window A\n"`。

每个窗口重复读取一次（`get_ax_state(..., full=true)`）：

| 窗口 | 第 1 次读 | 第 2 次读 | 结果 |
| --- | --- | --- | --- |
| `3134009` | `R8 window B\n` | `SCU-ONLY-WINDOW-1R8 window B\n` | 标记只在本窗口；`已编辑` 标记出现 |
| `3134010` | `R8 window A\n` | `R8 window A\n` | 无标记、无 `已编辑` |

两次读取均返回请求的 `window_id`，未出现串窗或内容错位。动作后 `scu windows` 的 z-order 顺序改变（`3134010` 排到前面），两个 ID 本身未变。

## 附加观察（不影响判定）

- **只按标题仍然歧义**：`scu dump --pid 94725 --window "scu-r8.txt"` 命中了 `3134010`（A 窗口）。同名窗口下标题选择仍不唯一，这是 `window_id` 路径存在的理由，不是本次回归的失败项。
- **`type_text` 是插入，不自动换行**：输入落在光标处（当时在开头），得到 `SCU-ONLY-WINDOW-1R8 window B`，与原文粘连。标记可 grep 到，但若使用者期望“整段替换”会误判。记录级，不影响身份验证。
- **关闭窗口后 `press_key` 的返回**：`cmd+w` 关闭后事后观察读不到界面，返回 `converged=false, treeChanged=unknown` 并附 `[window_not_found]`。这是预期的“窗口已消失”，不是失败。

## 清理

- 用 `cmd+z` 撤销了 id1 上的测试输入，文本回到 `R8 window B`，`已编辑` 标记消失；
- 再对两个窗口发 `cmd+w`，`list_windows` 返回“没有可枚举的窗口”，两个新窗口已关闭，**没有出现保存对话框，也没有点击任何系统对话框**；
- 用户原有实例 `pid 55304` 及其“打开”对话框未触碰；
- `/tmp/scu-r8-a/`、`/tmp/scu-r8-b/` 保留原文件（未保存修改）。

## 结论

**R8 通过。** 四项判定：两 ID 不同 PASS；`dump --window-id` 命中 PASS；截图 `window_id` 一致 PASS；标记不串窗 PASS。

仓库：HEAD 仍为 `d107c07`，无新提交、无 tag；工作树唯一变化是本文件。
