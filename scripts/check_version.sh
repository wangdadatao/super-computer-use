#!/usr/bin/env bash
# 版本一致性检查：代码里的版本/线协议版本与对外文档的「当前状态」行必须一致。
# 只断言当前状态句式，不扫历史版本与 verification 里的历史记录。
#
# 用法：scripts/check_version.sh
# 退出码：0 一致，1 有不一致。

set -euo pipefail
cd "$(dirname "$0")/.."

V=$(sed -n 's/^let scuVersion = "\(.*\)"$/\1/p' Sources/scu/main.swift)
W=$(sed -n 's/^public let scuNativeProtocolVersion = \([0-9][0-9]*\)$/\1/p' Sources/SCUWire/Messages.swift)
[ -n "$V" ] || { echo "❌ 读不到 scuVersion（Sources/scu/main.swift）"; exit 1; }
[ -n "$W" ] || { echo "❌ 读不到 scuNativeProtocolVersion（Sources/SCUWire/Messages.swift）"; exit 1; }

fail=0
need() { # need <文件> <固定字符串>
  if ! grep -qF -- "$2" "$1"; then
    echo "❌ $1 缺少：$2"
    fail=1
  fi
}

need docs/interfaces/mcp_surface.md "version: $V"
need docs/index.md "$V 已收口"
need skills/scu/INSTALL.md "scu-$V-macos-universal.zip"
need docs/interfaces/native_wire_protocol.md "当前协议版本为 **$W**"
need README.md "**${V}（"
need README.en.md "Version $V"

# CHANGELOG 可以有一段 `## Unreleased`（待发布条目）排在已发布版本之前；版本断言取第一个具名版本。
CHANGELOG_TOP=$(sed -n 's/^## //p' CHANGELOG.md | grep -v '^Unreleased$' | head -1)
case "$CHANGELOG_TOP" in
  "$V — "*) ;;
  *) echo "❌ CHANGELOG 首段不是 ${V}：${CHANGELOG_TOP}"; fail=1 ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "✅ 版本一致性：app $V / wire v$W"
fi
exit "$fail"
