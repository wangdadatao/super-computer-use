# ADR-0029 分发：可验证的 zip 优先，不把 ad-hoc 包说成已公证

- **状态**：已接受（0.4.0）
- **日期**：2026-10-21

<a id="distribution_decision"></a>

## 背景

到 0.3.0 为止 SCU 只支持源码构建。用户要求开始分发，但当前构建机只有
Apple Development 证书，没有 Developer ID Application/Installer 证书，也没有公证 profile。
同时 `scu` 与 `scu-native` 必须同目录、协议版本必须一致，任何“只复制一个二进制”的安装方式都会坏。
TCC 权限又归属于宿主应用，不属于 SCU 二进制。

因此分发要同时回答：交付什么、怎么签名、怎么验证、哪些事情不自动做。

## 决策

### 1. 先交付通用二进制 zip，不先做 pkg/dmg

产物是 `scu-<version>-macos-universal.zip`，包含 `scu`、`scu-native`、`install.sh`、
`VERSION`、`SHA256SUMS`、安装/使用文档和同版本工程文档。

不做 pkg/dmg 的理由：zip 足够透明，用户能看到两个二进制；pkg 需要 Installer 证书和提权，
当前没有证书，也无法完成真实的安装器首启验证。pkg/dmg 留到需要 staple 或安装器 UI 时。

### 2. 默认 ad-hoc，Developer ID 由环境变量显式选择

默认 `SCU_CODESIGN_IDENTITY=-`，产出本机可运行、可校验的 ad-hoc 包。
公开分发必须显式提供 Developer ID Application 身份，并带 hardened runtime 与时间戳。
脚本不内置任何证书、Apple ID 或密码。

### 3. 公证用 keychain profile，不在仓库保存凭据

有 `SCU_NOTARY_PROFILE` 且使用 Developer ID 时，构建脚本调用
`notarytool submit --wait`。凭据由 `notarytool store-credentials` 存在钥匙串。
没有 profile 时脚本明确警告“已签名但未公证”，不假装成功。

### 4. zip 不能 staple，接受联网取票

`notarytool` 接受 zip，但 `stapler` 不能作用于 zip。当前接受“公证后 Gatekeeper 联网取票”；
需要离线验证时再引入签名的 pkg/dmg 并 staple。

### 5. 安装脚本只复制，不碰宿主配置和 TCC

`install.sh` 校验签名后把两个二进制复制到 `~/bin/scu`（或 `--prefix`），运行一次
`scu permissions`，打印 MCP 配置片段。它不写 Cursor/Claude 配置，不打开系统设置，
不移除 quarantine。这两件事都需要用户明确同意。

### 6. 验证脚本是发布门槛

`scripts/verify_dist.sh` 从 zip 解压后检查架构、签名、校验和、原生进程启动、MCP 握手版本与
`list_apps`。Gatekeeper rejected 只记录，不作为 ad-hoc 包的失败；公开分发前另行要求 accepted。

### 7. 版本必须同源

包名、`VERSION`、`scuVersion`、`serverInfo.version` 必须一致；`scu` 与 `scu-native` 必须来自同一次构建。
不同版本的二进制不能混装，握手会拒绝。

## 取舍

**接受了当前包不能公开下载。** ad-hoc 签名会被 Gatekeeper 拒绝；这是没有 Developer ID 证书的
直接结果，不是可以靠文档绕过的限制。

**接受了 zip 没有 staple。** 离线机器可能无法完成 Gatekeeper 校验；需要时再做 pkg/dmg。

**接受了安装器不做配置。** 自动改宿主配置会越过“需要用户确认”的边界；多一步手工配置换取可解释性。

**接受了 Intel 只做切片验证。** 通用二进制包含 x86_64，但没有 Intel 实机跑过；不能声称 Intel 已验证。

## 后果

- 新增 `scripts/build_dist.sh`、`scripts/install_dist.sh`、`scripts/verify_dist.sh`；
- 新增 [分发文档](../operations/distribution.md)；
- `dist/` 加入 `.gitignore`，构建产物不提交；
- 0.4.0 产出 ad-hoc 通用 zip；Developer ID 路径已写好但未实际公证；
- README 与 INSTALL 不再说“没有分发包”，改为说明分发包的签名状态与限制；
- 分发包不改变线协议，仍是 v11。

## 相关文档

- [分发](../operations/distribution.md)
- [本地环境](../operations/local_setup.md)
- [macOS 权限](../operations/permissions.md)
- [协议版本](../decisions/adr_0012_protocol_versioning.md)
- [安装与自检](../../skills/scu/INSTALL.md)
