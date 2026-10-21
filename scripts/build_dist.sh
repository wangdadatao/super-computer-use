#!/usr/bin/env bash
# 构建可分发的 macOS zip：通用二进制、签名、校验和，可选公证。
#
# 用法：
#   scripts/build_dist.sh                         # ad-hoc 签名，适合本机/开发验证
#   SCU_CODESIGN_IDENTITY="Developer ID Application: Name (TEAM)" \
#     SCU_NOTARY_PROFILE=scu-notary scripts/build_dist.sh
#
# 输出（默认在 dist/）：
#   scu-<version>-macos-universal/               已签名、可直接运行的目录
#   scu-<version>-macos-universal.zip            分发包
#   scu-<version>-macos-universal.zip.sha256     压缩包校验和
#
# 环境变量：
#   SCU_DIST_ARCHS       默认 "arm64 x86_64"；只支持 SwiftPM 认识的架构
#   SCU_CODESIGN_IDENTITY 默认 "-"（ad-hoc）；Developer ID 签名才可能通过 Gatekeeper
#   SCU_NOTARY_PROFILE   notarytool 的 keychain profile；只有 Developer ID 签名时才使用
#   SCU_SKIP_NOTARIZE=1  显式跳过公证（默认在没有 profile 时也会跳过并警告）
#   SCU_DIST_DIR         输出目录，默认 dist
#
# 不在脚本里保存 Apple ID / 密码 / API key；notarytool 使用钥匙串 profile。
# @project-doc docs/operations/distribution.md#distribution_build

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^let scuVersion = "\(.*\)"$/\1/p' Sources/scu/main.swift)"
[ -n "$VERSION" ] || { echo "❌ 读不到 Sources/scu/main.swift 里的 scuVersion" >&2; exit 1; }
case "$VERSION" in *[!0-9A-Za-z._-]*) echo "❌ 版本号含有不适合文件名的字符：$VERSION" >&2; exit 1;; esac

ARCHS="${SCU_DIST_ARCHS:-arm64 x86_64}"
DIST_DIR="${SCU_DIST_DIR:-dist}"
IDENTITY="${SCU_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${SCU_NOTARY_PROFILE:-}"
SKIP_NOTARY="${SCU_SKIP_NOTARIZE:-}"
ARCH_LABEL="$(printf '%s' "$ARCHS" | tr ' ' '-')"
[ "$ARCH_LABEL" = "arm64-x86_64" ] && ARCH_LABEL="universal"
STAGE="$DIST_DIR/scu-$VERSION-macos-$ARCH_LABEL"
ZIP="$STAGE.zip"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "❌ 分发包只能在 macOS 上构建（当前 $(uname -s)）" >&2
  exit 1
fi

build_args=(-c release)
for arch in $ARCHS; do build_args+=(--arch "$arch"); done

echo "==> 构建 $VERSION（$ARCHS）"
swift build "${build_args[@]}" 2>&1 | tail -5
BIN="$(swift build "${build_args[@]}" --show-bin-path)"
for f in scu scu-native; do
  [ -x "$BIN/$f" ] || { echo "❌ 构建产物缺少 $BIN/$f" >&2; exit 1; }
done

echo "==> 校验架构"
for f in scu scu-native; do
  actual="$(lipo -archs "$BIN/$f")"
  for arch in $ARCHS; do
    printf '%s\n' "$actual" | tr ' ' '\n' | grep -qx "$arch" || {
      echo "❌ $f 缺少架构 $arch（实际：$actual）" >&2; exit 1;
    }
  done
done

if [ "$IDENTITY" != "-" ]; then
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$IDENTITY"; then
    echo "❌ 钥匙串里找不到代码签名身份：$IDENTITY" >&2
    echo "   可用身份：" >&2
    security find-identity -v -p codesigning 2>/dev/null | sed 's/^/     /' >&2
    exit 1
  fi
fi

echo "==> 准备 $STAGE"
rm -rf "$STAGE" "$ZIP" "$ZIP.sha256"
mkdir -p "$STAGE"
install -m 0755 "$BIN/scu" "$STAGE/scu"
install -m 0755 "$BIN/scu-native" "$STAGE/scu-native"
# 根目录副本的链接从 ../../docs/ 改为包内 docs/；skills/ 下的原始副本保持相对链接。
sed 's#](\.\./\.\./docs/#](docs/#g' skills/scu/INSTALL.md > "$STAGE/INSTALL.md"
sed 's#](\.\./\.\./docs/#](docs/#g' skills/scu/SKILL.md > "$STAGE/SKILL.md"
chmod 0644 "$STAGE/INSTALL.md" "$STAGE/SKILL.md"
install -m 0755 scripts/install_dist.sh "$STAGE/install.sh"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"
cp -R docs "$STAGE/docs"
cp -R skills "$STAGE/skills"
# 根目录副本的 docs/ 链接在包内可达；skills/ 保留原始相对链接。

echo "==> 签名（$IDENTITY）"
for f in scu-native scu; do
  if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$STAGE/$f"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE/$f"
  fi
  codesign --verify --strict --verbose=2 "$STAGE/$f"
done

echo "==> 生成 SHA256SUMS"
(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -print | sort | while IFS= read -r f; do
    shasum -a 256 "$f"
  done > SHA256SUMS
)

echo "==> 打包 $ZIP"
# 不写入 __MACOSX/AppleDouble；可执行位与内嵌签名仍在
(cd "$DIST_DIR" && ditto -c -k --norsrc --keepParent "$(basename "$STAGE")" "$(basename "$ZIP")")
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")

if [ "$IDENTITY" = "-" ]; then
  echo "⚠️  当前是 ad-hoc 签名；从网络下载后 Gatekeeper 可能拒绝运行。"
  echo "   要对外分发，请用 Developer ID Application 签名并公证。"
elif [ -z "$SKIP_NOTARY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "==> 提交公证（profile: $NOTARY_PROFILE）"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "ℹ️  zip 已公证。zip 本身不能 staple；Gatekeeper 需要联网取票据。"
elif [ -n "$SKIP_NOTARY" ]; then
  echo "⚠️  已显式跳过公证（SCU_SKIP_NOTARIZE=1）。"
else
  echo "⚠️  没有 SCU_NOTARY_PROFILE，已签名但未公证；对外分发前必须补公证。"
fi

echo
echo "✅ 完成"
echo "   目录：$STAGE"
echo "   压缩包：$ZIP"
echo "   校验：$ZIP.sha256"
echo "   验证：scripts/verify_dist.sh '$ZIP'"
