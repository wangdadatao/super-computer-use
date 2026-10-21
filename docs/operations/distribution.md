# 分发

<a id="distribution"></a>

## 目标与边界

SCU 的分发包是一个 **macOS 通用二进制 zip**，里面只有两个可执行文件、安装脚本、使用文档与校验和。
它不写宿主 MCP 配置、不代替用户授予辅助功能或屏幕录制权限，也不包含自动更新。

当前提供的 0.4.0 包是 **ad-hoc 签名**：可以在本机运行，但不能作为公开分发的 Gatekeeper 凭证。
Developer ID 签名与公证的流水线已经写好，但这台构建机没有 Developer ID Application/Installer
证书，也没有公证 profile，因此没有产出“已公证”的包。不要把 ad-hoc 包描述成已公证或可直接公开下载。

## 产物布局

```text
scu-<version>-macos-universal/
  scu                      # 协议层 / MCP 入口
  scu-native               # 原生层 sidecar，必须与 scu 同目录
  install.sh               # 复制到稳定目录，不修改宿主配置
  VERSION
  SHA256SUMS
  INSTALL.md
  SKILL.md
  docs/                    # 同版本工程文档
  skills/                  # 原始 agent 文档
```

`scu` 启动时在**自己所在目录**找 `scu-native`；两者不是同一个包版本时会握手失败。
分发包不包含 `scu-fixture`，它只用于测试。

<a id="distribution_build"></a>

## 构建

```bash
# 默认：arm64 + x86_64 通用二进制，ad-hoc 签名
scripts/build_dist.sh

# 有 Developer ID 时：
SCU_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
SCU_NOTARY_PROFILE=scu-notary \
scripts/build_dist.sh
```

构建脚本做这些事：

1. 从 `Sources/scu/main.swift` 读取版本号，要求与包名一致；
2. `swift build -c release --arch arm64 --arch x86_64`；
3. 用 `lipo` 核对两个可执行文件都包含期望架构；
4. 复制二进制、文档与 `install.sh` 到暂存目录；
5. `scu-native` 先签、`scu` 后签；
6. 生成 `SHA256SUMS`，再打 zip 与压缩包 `.sha256`；
7. 有 Developer ID 且给了 `SCU_NOTARY_PROFILE` 时调用 `notarytool submit --wait`。

环境变量：

| 变量 | 默认 | 用途 |
| --- | --- | --- |
| `SCU_DIST_ARCHS` | `arm64 x86_64` | 期望架构；只支持 SwiftPM 能构建的架构 |
| `SCU_CODESIGN_IDENTITY` | `-`（ad-hoc） | 代码签名身份；公开分发必须用 Developer ID Application |
| `SCU_NOTARY_PROFILE` | 空 | `notarytool` 的钥匙串 profile 名，不把密码写进仓库 |
| `SCU_SKIP_NOTARIZE` | 空 | 显式跳过公证；仍会保留警告 |
| `SCU_DIST_DIR` | `dist` | 输出目录 |

没有 Developer ID 时脚本仍会产出可用包，但会打印 Gatekeeper 警告。**脚本不会把 ad-hoc 包伪装成已签名发布包。**

<a id="distribution_sign_notarize"></a>

## 签名与公证

### 当前可做的

- 本机自测：默认 ad-hoc 签名，`codesign --verify --strict` 通过；
- 组织内部分发：使用 Developer ID Application 签名，并由组织决定是否接受未公证包；
- 对外公开分发：Developer ID Application 签名 + `notarytool` 公证，二者缺一不可。

### 签名顺序

先签 `scu-native`，再签 `scu`。两者都是独立 Mach-O，不是 app bundle，所以不需要 `--deep`。
Developer ID 路径带 `--options runtime --timestamp`；ad-hoc 路径不带 hardened runtime。

### 公证

```bash
xcrun notarytool store-credentials scu-notary \
  --apple-id "<apple-id>" --team-id "<team-id>" --password "<app-specific-password>"
SCU_CODESIGN_IDENTITY="Developer ID Application: ..." \
SCU_NOTARY_PROFILE=scu-notary scripts/build_dist.sh
```

`notarytool` 接受 zip；zip **不能 staple**，Gatekeeper 需要联网取票据。需要离线可验证时，
后续应增加签名的 `.pkg` 或 `.dmg` 再 staple；当前未做。

<a id="distribution_verify"></a>

## 验证

构建后必须跑：

```bash
scripts/verify_dist.sh dist/scu-<version>-macos-universal.zip
```

它检查：

- 压缩包内 `scu` 与 `scu-native` 齐全、可执行、同目录；
- `lipo -archs` 包含 `arm64` 与 `x86_64`；
- 两个二进制都通过 `codesign --verify --strict`；
- 打印签名类型与 Gatekeeper 结果；
- `SHA256SUMS` 与压缩包 `.sha256` 一致；
- 从解压目录运行 `scu permissions` 退出码为 0 或 2；
- `scu mcp` 握手返回 `serverInfo.version` 等于 `VERSION`，`list_apps` 有结果。

**验证脚本不会把 Gatekeeper rejected 当成失败**：ad-hoc 或未公证的包本来就会被拒。
公开分发前要额外确认 `spctl -a -t exec` 为 accepted。

<a id="distribution_install"></a>

## 安装

```bash
shasum -a 256 -c scu-<version>-macos-universal.zip.sha256
unzip scu-<version>-macos-universal.zip
cd scu-<version>-macos-universal
./install.sh                 # 默认 ~/bin/scu
# 或：./install.sh --prefix "$HOME/Applications/scu"
```

安装脚本会：

1. 校验两个二进制的签名；
2. 复制 `scu` / `scu-native` 到目标目录（默认 `~/bin/scu`）；
3. 运行 `scu permissions`，退出码 0 或 2 都继续；
4. 打印宿主 MCP 配置片段。

它**不会**修改宿主配置，也不会授予 TCC 权限。把 `command` 改成安装后的绝对路径，
然后让用户完全退出并重启宿主。

## Gatekeeper 与 TCC

- **Gatekeeper**：从网络下载的 ad-hoc 包会被拦；Developer ID + 公证的包才会被放行。
  不要在文档或脚本里自动移除 `com.apple.quarantine`。
- **辅助功能 / 屏幕录制**：权限按**启动 MCP 服务的宿主应用**归属，不按 `scu` 二进制归属。
  安装分发包不等于授权；用户仍需在系统设置里给宿主打开开关并重启宿主。
- **同目录约束**：把 `scu` 单独复制到别处会找不到 `scu-native`，返回 `platform_unavailable`。
  符号链接可以工作，因为 `scu` 会先解析真实路径。

## 版本与兼容性

- 包版本来自 `scuVersion`；`VERSION`、`serverInfo.version`、包名必须一致。
- `scu` 与 `scu-native` 的线协议版本在握手时校验；不能混用不同版本的二进制。
- 当前线协议 v11；分发包不改变协议，只改变交付方式。
- 升级：覆盖安装 `scu` 与 `scu-native`，然后重启宿主；没有自动更新。

## 当前证据与限制

2026-10-21 在 macOS 26.6.2 / arm64 上构建并验证了 `0.4.0` 通用包：

- 通用二进制包含 `x86_64` 与 `arm64`；
- 两个二进制 ad-hoc 签名，`codesign --verify --strict` 通过；
- `spctl` 拒绝（符合 ad-hoc 预期）；
- `scu permissions`、`scu mcp` 握手与 `list_apps` 从解压目录运行通过；
- `install.sh` 安装到临时前缀后再次运行 `permissions` 通过。

限制：

- 没有 Developer ID 证书，**没有实际公证**；
- 没有 `.pkg` / `.dmg`，zip 不能 staple；
- 没有自动更新、卸载器或安装器 UI；
- 没有在另一台干净 Mac 上做 Gatekeeper/TCC 首启验证；
- 没有 Intel 实机运行验证，只验证了 x86_64 切片存在。

## 相关文档

- [本地环境](local_setup.md)
- [macOS 权限](permissions.md)
- [测试策略](testing.md)
- [ADR-0029](../decisions/adr_0029_distribution.md)
- [安装与自检](../../skills/scu/INSTALL.md)
