#!/usr/bin/env bash
# 验证一个分发包 zip 或已解压目录：文件齐全、架构、签名、版本握手、MCP 只读冒烟。
# 用法：scripts/verify_dist.sh dist/scu-<version>-macos-universal.zip
#       scripts/verify_dist.sh dist/scu-<version>-macos-universal
# 环境变量：SCU_EXPECT_ARCHS（默认 "arm64 x86_64"）
#
# @project-doc docs/operations/distribution.md#distribution_verify

set -euo pipefail
ARTIFACT="${1:-}"
[ -n "$ARTIFACT" ] || { echo "用法：$0 <zip|目录>" >&2; exit 64; }
[ -e "$ARTIFACT" ] || { echo "❌ 不存在：$ARTIFACT" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/scu-verify.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

if [ -d "$ARTIFACT" ]; then
  SRC="$ARTIFACT"
else
  unzip -q "$ARTIFACT" -d "$TMP"
  SRC="$(find "$TMP" -maxdepth 3 -type f -name scu -print -quit | xargs -I{} dirname {})"
fi
[ -n "$SRC" ] && [ -x "$SRC/scu" ] || { echo "❌ 找不到 scu/scu-native 目录" >&2; exit 1; }
[ -x "$SRC/scu-native" ] || { echo "❌ 缺少 scu-native（必须与 scu 同目录）" >&2; exit 1; }
[ -f "$SRC/VERSION" ] || { echo "❌ 缺少 VERSION" >&2; exit 1; }
VERSION="$(cat "$SRC/VERSION")"
echo "==> 版本 $VERSION，目录 $SRC"

echo "==> 文件架构"
for f in scu scu-native; do
  archs="$(lipo -archs "$SRC/$f")"
  echo "   $f: $archs"
  for arch in ${SCU_EXPECT_ARCHS:-arm64 x86_64}; do
    printf '%s\n' "$archs" | tr ' ' '\n' | grep -qx "$arch" || {
      echo "❌ $f 缺少架构 $arch" >&2; exit 1;
    }
  done
done

echo "==> 代码签名"
for f in scu scu-native; do
  codesign --verify --strict --verbose=2 "$SRC/$f"
  dv="$(codesign -dv "$SRC/$f" 2>&1)"
  case "$dv" in
    *"Authority=Developer ID Application"*) echo "   $f: Developer ID Application" ;;
    *"Signature=adhoc"*) echo "   $f: ad-hoc（不能作为公开分发的 Gatekeeper 凭证）" ;;
    *) echo "   $f: 已签名（非 Developer ID Application）" ;;
  esac
done
if spctl -a -t exec "$SRC/scu" >/dev/null 2>&1; then
  echo "   Gatekeeper: accepted"
else
  echo "   Gatekeeper: rejected（ad-hoc 或未公证时正常）"
fi

echo "==> SHA256SUMS"
if [ -f "$SRC/SHA256SUMS" ]; then
  (cd "$SRC" && shasum -a 256 -c SHA256SUMS >/dev/null) \
    && echo "   ✅ 校验和一致" || { echo "❌ SHA256SUMS 不匹配" >&2; exit 1; }
else
  echo "⚠️  没有 SHA256SUMS（仅目录验证时可能是正常的）"
fi

echo "==> 原生进程与权限"
set +e
(cd "$SRC" && ./scu permissions >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "❌ scu permissions 返回 $rc（期望 0 或 2）" >&2; exit 1
fi
echo "   scu permissions 退出码 $rc（0=已授权，2=未授权，均可接受）"

echo "==> MCP 握手与 list_apps"
SOCK="$(mktemp -d "$TMP/socket.XXXXXX")"
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
apps='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}'
OUT="$(printf '%s\n%s\n' "$init" "$apps" | TMPDIR="$SOCK/" "$SRC/scu" mcp 2>/dev/null)"
printf '%s\n' "$OUT" | grep -q '"name":"scu"' || { echo "❌ MCP 握手没有看到 serverInfo.scu" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q "\"version\":\"$VERSION\"" || {
  echo "❌ serverInfo.version 不是 $VERSION" >&2; exit 1;
}
printf '%s\n' "$OUT" | grep -q '"result"' || { echo "❌ list_apps 没有 result" >&2; exit 1; }
echo "   ✅ 握手、版本与 list_apps 正常"

echo "==> 压缩包校验和"
if [ -f "$ARTIFACT.sha256" ]; then
  (cd "$(dirname "$ARTIFACT")" && shasum -a 256 -c "$(basename "$ARTIFACT").sha256" >/dev/null) \
    && echo "   ✅ $ARTIFACT.sha256 一致" || { echo "❌ 压缩包校验和不一致" >&2; exit 1; }
fi

echo
echo "✅ 分发包验证通过：$VERSION"
