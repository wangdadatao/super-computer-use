#!/usr/bin/env bash
# 提交前统一检查：文档、构建、测试、命令行冒烟。
#
# 用法：scripts/check.sh
# 退出码：0 全部通过，1 任一项失败。
#
# 启用为 git pre-commit：  git config core.hooksPath scripts/hooks
# 临时跳过（不推荐）：     git commit --no-verify

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
step() { echo; echo "━━ $1 ━━"; }

step "1/4 文档与代码锚点"
scripts/check_docs.sh || fail=1

step "2/4 构建"
swift build 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

step "3/4 测试"
swift test 2>&1 | grep -E "✘|error:|Test run with" | tail -20
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

# 冒烟：失败路径也必须清理临时目录（回归：失败路径曾经调用 exit() 绕过清理）。
step "4/4 命令行冒烟（失败路径不泄漏临时目录）"
if [ "$fail" -eq 0 ]; then
  bin="$(swift build --show-bin-path)/scu"
  tmp="$(mktemp -d /tmp/scu-smoke.XXXXXX)"
  TMPDIR="$tmp/" "$bin" dump >/dev/null 2>&1          # 用法错误，退出码 64
  rc1=$?
  TMPDIR="$tmp/" "$bin" dump --pid 1 --depth 999 >/dev/null 2>&1   # 深度越界，退出码 64
  rc2=$?
  TMPDIR="$tmp/" "$bin" permissions >/dev/null 2>&1   # 0 或 2，均须清理
  rc3=$?
  leaked="$(ls "$tmp" | wc -l | tr -d ' ')"
  rm -rf "$tmp"
  if [ "$rc1" -ne 64 ] || [ "$rc2" -ne 64 ] || { [ "$rc3" -ne 0 ] && [ "$rc3" -ne 2 ]; }; then
    echo "   ❌ 退出码不符：dump=${rc1} depth=${rc2} permissions=${rc3}"
    fail=1
  elif [ "$leaked" -ne 0 ]; then
    echo "   ❌ 泄漏 ${leaked} 个临时目录"
    fail=1
  else
    echo "   ✅ 退出码符合预期，无泄漏（permissions 退出码 ${rc3}）"
  fi
else
  echo "   跳过（前面的步骤已失败）"
fi

echo
if [ "$fail" -eq 0 ]; then echo "✅ 全部通过"; else echo "❌ 有检查失败"; fi
exit $fail
