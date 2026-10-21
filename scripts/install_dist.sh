#!/usr/bin/env bash
# 把分发包里的 scu 与 scu-native 安装到稳定目录。
# 这是分发包内的 install.sh 源文件；默认安装到 ~/bin/scu，不修改宿主 MCP 配置，不需要 sudo。
#
# 用法：./install.sh [--prefix <目录>]
#       SCU_PREFIX=<目录> ./install.sh
#
# @project-doc docs/operations/distribution.md#distribution_install

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${SCU_PREFIX:-$HOME/bin/scu}"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
}
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      [ $# -ge 2 ] || usage
      PREFIX="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) echo "不认识的参数：$1" >&2; usage ;;
  esac
done

[ -x "$HERE/scu" ] || { echo "❌ 找不到 $HERE/scu；请在解压后的完整目录里运行。" >&2; exit 1; }
[ -x "$HERE/scu-native" ] || { echo "❌ 找不到 $HERE/scu-native；scu 与 scu-native 必须放在同一目录。" >&2; exit 1; }
[ -f "$HERE/VERSION" ] || { echo "❌ 找不到 VERSION；分发包不完整。" >&2; exit 1; }

VERSION="$(cat "$HERE/VERSION")"
if ! codesign --verify --strict "$HERE/scu" 2>/dev/null || ! codesign --verify --strict "$HERE/scu-native" 2>/dev/null; then
  echo "❌ 分发包的代码签名校验失败；不要安装被篡改的二进制。" >&2
  exit 1
fi

if xattr -p com.apple.quarantine "$HERE/scu" >/dev/null 2>&1; then
  echo "⚠️  二进制带 com.apple.quarantine。ad-hoc 分发包可能被 Gatekeeper 拦截；"
  echo "   请确认来源，或按 docs/operations/distribution.md 的说明处理。"
fi

mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
install -m 0755 "$HERE/scu" "$PREFIX/scu"
install -m 0755 "$HERE/scu-native" "$PREFIX/scu-native"
printf '%s\n' "$VERSION" > "$PREFIX/VERSION"

echo "已安装 SCU $VERSION 到 $PREFIX"
set +e
"$PREFIX/scu" permissions
rc=$?
set -e
case "$rc" in
  0) echo "✅ 辅助功能权限已授予当前宿主。" ;;
  2) echo "⚠️  当前宿主还没有辅助功能权限；按 INSTALL.md 第 6 步由用户授权，然后完全退出并重启宿主。" ;;
  *)
    echo "❌ permissions 返回 $rc；本次安装不完整或 scu-native 无法启动，请检查 $PREFIX。" >&2
    exit 1 ;;
esac

cat <<JSON
把下面这段加入宿主的 MCP 配置（路径已是绝对路径；动作档要保留 --actions）：

{"mcpServers":{"scu":{"command":"$PREFIX/scu","args":["mcp","--actions"]}}}

SCU 不会自动修改宿主配置，也不会代替用户授予辅助功能/屏幕录制权限。
JSON
