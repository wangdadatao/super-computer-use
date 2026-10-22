# SCU 安装与自检（给 agent 的步骤）

这份文档假设**你是一个 agent**，要在一台 macOS 机器上把 SCU 装好、验证通过，然后自己用。
先读 [SKILL.md](SKILL.md) 了解能力边界；这里只讲安装与验证。

## 0. 你能做与不能做

| 类别 | 事项 |
| --- | --- |
| **可以自动做** | 检查环境、从源码构建、复制二进制、写宿主配置（写前备份）、只读自检、排错 |
| **需要用户确认** | 修改宿主的 MCP 配置、重启宿主、选择自检时读取哪个应用 |
| **不能代做** | 在系统设置里授予辅助功能（TCC 必须人点）；替用户决定是否安装；绕过被拒绝的动作 |

安装前先向用户说明：要改哪个配置文件、会把二进制放在哪、需要一次手动授权。

## 1. 检查环境

```bash
sw_vers -productVersion    # 需要 14.4 或更高
uname -m                   # arm64 或 x86_64
```

从源码构建还需要 Swift：

```bash
swift --version            # 期望 6.x
```

宿主必须支持 MCP stdio（Cursor、Claude Desktop、其他 MCP 客户端）。

## 2. 取得二进制

### 2.1 用分发包（如果拿到了）

0.4.0 起可以构建 macOS 通用二进制 zip，但仓库**暂不提供公开下载**：当前包是
**ad-hoc 签名、未公证**，从网络下载后会被 Gatekeeper 拦截。没有拿到可信分发包时走 2.2。
不要自行移除 quarantine，也不要把 ad-hoc 包说成已公证。

```bash
shasum -a 256 -c scu-0.4.0-macos-universal.zip.sha256
unzip scu-0.4.0-macos-universal.zip
cd scu-0.4.0-macos-universal
./install.sh                    # 默认安装到 ~/bin/scu
# 或：./install.sh --prefix "$HOME/Applications/scu"
```

`install.sh` 会校验两个二进制的签名、复制到稳定目录并运行一次 `scu permissions`，
不会修改宿主配置。安装后 `scu` 与 `scu-native` 必须仍在同一目录。

### 2.2 从源码构建（没有合适分发包时）

```bash
cd <仓库根目录>
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
ls "$BIN/scu" "$BIN/scu-native"
```

通用二进制用 `swift build -c release --arch arm64 --arch x86_64`。

- `scu` 会在**自己所在的目录**找 `scu-native`，两者必须放在一起。
- `scu-fixture` 只有测试需要，安装时不用复制。
- 分发包解压后同样需要 `scu` 与 `scu-native` 在同一目录；单独复制一个会报 `platform_unavailable`。

## 3. 放置到稳定目录

分发包用 `install.sh` 时已处理。源码构建时不要放在 `.build/` 里（会被 `swift build` 清理），建议 `~/bin/scu/`：

```bash
mkdir -p ~/bin/scu
cp "$BIN/scu" "$BIN/scu-native" ~/bin/scu/
chmod +x ~/bin/scu/scu ~/bin/scu/scu-native
~/bin/scu/scu permissions; echo "退出码 $?"
```

退出码 2 表示还没有辅助功能权限（第 6 步再处理）。

## 4. 写宿主配置

**先备份**目标文件，再写入。动作档需要 `--actions`；只读试用可以去掉。
如需限制可操作的应用，在参数里加 `--allow-app <bundle|名称|路径>`（可重复）或
`--allow-app-file <path>`；列表外的应用会在读取/动作前被拒绝。

Cursor（`~/.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "scu": {
      "command": "/Users/<用户名>/bin/scu/scu",
      "args": ["mcp", "--actions"]
    }
  }
}
```

Claude Desktop（`~/Library/Application Support/Claude/claude_desktop_config.json`）用同样的结构。

其他宿主：传输方式选 stdio，命令是上面的绝对路径，参数是 `mcp` 或 `mcp --actions`。
路径必须是绝对路径，宿主不会继承你的 shell 环境。

写完后让用户确认内容，再进入下一步。

## 5. 重启宿主

MCP 配置与权限都在宿主启动时读取。让用户**完全退出**（⌘Q）再打开；
只关窗口不算。

## 6. 授权（必须由人完成）

1. 让用户运行：

   ```bash
   open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
   ```

2. 在「辅助功能」里给**宿主应用**（Cursor、终端、Claude 等）打开开关；
   没有条目就点 `+` 添加宿主。

3. 让用户完全退出并重启宿主。

4. 验证：

   ```bash
   ~/bin/scu/scu permissions; echo "退出码 $?"
   ```

   0 = 已授予；2 = 未授予。

**你不能代替用户点这个开关，也不要用 `tccutil` 去重置或伪造权限。**
权限归属于宿主进程，不是二进制，也不是整台机器；换宿主就要重新确认。

## 7. 自检（只读）

宿主重启后，按顺序调用：

1. `check_permissions` → 应报告已授予。
2. `list_apps` → 至少有一个应用。
3. `get_ax_state(pid=…)` 读一个安全应用（访达或活动监视器）→ 应看到标题行、令牌与元素表。

**自检不要自动点击或输入。** 需要验证动作时，让用户指定一个安全目标（例如一个空白的输入框），
并且一次只做一个动作、做完立即重读。自检报告应包含：SCU 版本、宿主、权限状态、读到的应用。

## 8. 排错

| 症状 | 处理 |
| --- | --- |
| `scu permissions` 退出码 2 | 授权没生效：确认宿主、完全退出重开、必要时删掉辅助功能里的旧条目重新添加 |
| 宿主里看不到 scu 工具 | 配置路径不是绝对路径、JSON 不合法、或宿主没重启 |
| 调用 `click` 返回「未知工具」 | 启动参数少了 `--actions` |
| `platform_unavailable` | `scu-native` 不在 `scu` 同目录，或原生进程被杀；重试一次并检查目录 |
| 读不到某个应用的树 | 该应用不暴露无障碍树，或权限没给到宿主；先换访达验证 |
| 读取被截断 | 树太大：用 `focus` 定点读，或调大 `budget_ms` / `max_elements` |

手动握手（不经过宿主，验证服务本身）：

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ~/bin/scu/scu mcp
```

## 9. 卸载

1. 从宿主配置里删掉 `scu` 条目（先备份）。
2. 退出宿主。
3. 删除 `~/bin/scu/`。
4. 可选：在「辅助功能」里移除宿主条目。若该宿主还在跑其他自动化，**不要**移除。

## 相关文档

- [SKILL.md](SKILL.md)：使用指导（核心循环、动作选择、效果摘要、错误处理）
- [docs/operations/permissions.md](../../docs/operations/permissions.md)：权限归属与排障
- [docs/operations/local_setup.md](../../docs/operations/local_setup.md)：构建、命令行与 MCP 冒烟
- [docs/interfaces/mcp_surface.md](../../docs/interfaces/mcp_surface.md)：工具与输出格式
