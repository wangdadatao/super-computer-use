# 0.4.0 分发包验证（macOS 通用 zip）

- 日期：2026-10-21
- 环境：macOS 26.6.2，Apple Silicon（arm64）；Xcode 27.1；Swift 6.4
- 目的：验证通用二进制 zip 的架构、签名、校验和、解压后的 MCP 冒烟与安装脚本
- 产物：`dist/scu-0.4.0-macos-universal.zip`，版本 `0.4.0`，线协议 v11

## 构建

```text
scripts/build_dist.sh
```

输出：

```text
dist/scu-0.4.0-macos-universal/
  scu          2,440,160 bytes
  scu-native   1,294,464 bytes
  install.sh
  VERSION      0.4.0
  SHA256SUMS
  INSTALL.md / SKILL.md / docs / skills
dist/scu-0.4.0-macos-universal.zip          1.3 MB（1,327,872 bytes），66 个文件
dist/scu-0.4.0-macos-universal.zip.sha256
```

压缩包 SHA-256：

```text
9ac56039fb41cf886b315b1f6943a28b26fef020be6cc13c6d7d94eeb530ac9d
```

## 架构与签名

```text
scu:        x86_64 arm64
scu-native: x86_64 arm64
```

两个可执行文件都用 `codesign --sign -` 做 ad-hoc 签名：

```text
CodeDirectory ... flags=0x2(adhoc)
Signature=adhoc
```

`codesign --verify --strict` 通过；`spctl -a -t exec` 拒绝。这是 ad-hoc 包的预期结果，
不是公证失败的证据，也不能作为公开分发的 Gatekeeper 凭证。

构建机只有 Apple Development 证书，没有 Developer ID Application/Installer 证书：

```text
1) Apple Development: redacted@example.invalid (redacted_team_id)
2) Apple Development: redacted@example.invalid (redacted_team_id)
```

因此 **没有执行公证**；`notarytool` 路径只存在于脚本中，未在本机实际跑过。

## 验证脚本

```text
scripts/verify_dist.sh dist/scu-0.4.0-macos-universal.zip
```

结果：

- `lipo` 两个架构都在；
- 两个二进制 `codesign --verify --strict` 通过；
- 包内 `SHA256SUMS` 与压缩包 `.sha256` 一致；
- 从解压目录运行 `scu permissions`，退出码 0；
- `scu mcp` 的 `initialize` 返回 `serverInfo.version=0.4.0`，`list_apps` 有结果；
- Gatekeeper 为 rejected，脚本把它记录为预期状态而不是通过条件。

## 安装脚本

在临时前缀上运行：

```text
./install.sh --prefix /tmp/scu-install.XXXXXX
```

结果：

- 两个二进制复制到前缀，`VERSION` 写入；
- 安装后的 `scu permissions` 返回 0；
- 脚本打印了 MCP 配置片段，没有修改任何宿主配置；
- 临时目录随后删除。

## 限制

- 未公证；没有 Developer ID 证书，无法验证公开下载后的 Gatekeeper 首启。
- 只在 arm64 本机运行；x86_64 只验证了切片存在，没有 Intel 实机验证。
- zip 不能 staple；即使公证，离线机器也可能需要联网取票。
- 没有 pkg/dmg、自动更新、卸载器或安装器 UI。
- 没在另一台干净 Mac 上验证权限引导；TCC 权限仍归宿主应用，不归 SCU 二进制。

## 结论

通用 zip 的构建、ad-hoc 签名、校验和、解压后 MCP 冒烟与安装脚本在本机成立。
它适合本机/内部验证；**不是可直接公开下载的已公证发行包**。公开分发还差
Developer ID Application 签名、公证与一台干净机器的 Gatekeeper/TCC 首启验证。
