#!/usr/bin/env bash
# 用仓库根目录的 .swift-format 统一格式化 Swift 代码。
#
# 用法：
#   scripts/format.sh                 格式化 Sources/ 与 Tests/ 下全部 Swift 文件
#   scripts/format.sh --check         只检查，不写回；有不符合项时退出 1
#   scripts/format.sh Sources/Foo.swift Tests/BarTests.swift
#
# 说明：现有代码树尚未整体重排，scripts/check.sh 不强制调用本脚本。
# 建议对自己改过的文件运行，避免把无关文件带进 diff。
set -euo pipefail
cd "$(dirname "$0")/.."

check=0
if [ "${1:-}" = "--check" ]; then
  check=1
  shift
elif [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,13p' "$0"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find Sources Tests -type f -name '*.swift' | sort)
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "format: 没有 Swift 文件"
  exit 0
fi

if command -v swift-format >/dev/null 2>&1; then
  sf="$(command -v swift-format)"
elif sf="$(xcrun --find swift-format 2>/dev/null)" && [ -x "$sf" ]; then
  :
else
  echo "format: 找不到 swift-format；安装 Xcode 命令行工具，或 npm i -g swift-format" >&2
  exit 2
fi

config=".swift-format"
if [ "$check" = "1" ]; then
  echo "format: 检查 ${#files[@]} 个文件"
  "$sf" lint --strict --configuration "$config" "${files[@]}"
else
  echo "format: 格式化 ${#files[@]} 个文件"
  "$sf" format --in-place --configuration "$config" "${files[@]}"
fi
