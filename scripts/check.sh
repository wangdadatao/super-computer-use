#!/usr/bin/env bash
# 提交前统一检查：文档、格式、构建、测试、命令行与 MCP 冒烟（含 SIGKILL 后的回收）。前面任一步失败则冒烟不再执行。
# 真实应用测试需要宿主有辅助功能权限；没有权限时本脚本失败并提示，显式设置 SCU_SKIP_LIVE=1 才会跳过这些测试。
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

step "1/5 文档与代码锚点"
scripts/check_docs.sh || fail=1

step "2/5 代码格式"
scripts/format.sh --check || fail=1

step "3/5 构建"
swift build 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

step "4/5 测试"
# 真实应用测试（夹具、访达）需要宿主有辅助功能权限。没有权限时在这里就说清楚，而不是让十几个测试各自失败。
if [ -z "${SCU_SKIP_LIVE:-}" ]; then
  "$(swift build --show-bin-path)/scu" permissions >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "❌ 当前宿主没有辅助功能权限，真实应用测试无法运行。"
    echo "   授权后重试（见 docs/operations/permissions.md），或明确跳过：SCU_SKIP_LIVE=1 scripts/check.sh"
    echo "   （跳过时夹具与访达上的验证没有被执行，提交说明里应写明）"
    echo "   本次仍运行不依赖权限的测试，供参考，但整体记为失败。"
    export SCU_SKIP_LIVE=1
    fail=1
  fi
fi
swift test 2>&1 | grep -E "✘|error:|Test run with" | tail -20
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

# 冒烟：失败路径也必须清理临时目录（回归：失败路径曾经调用 exit() 绕过清理）。
step "5/5 命令行与 MCP 冒烟（帮助、退出码、失败路径、被杀路径都不泄漏临时目录）"
if [ "$fail" -eq 0 ]; then
  bin="$(swift build --show-bin-path)/scu"
  tmp="$(mktemp -d /tmp/scu-smoke.XXXXXX)"
  "$bin" --help >/dev/null 2>&1                       # 帮助，退出码 0
  rc_help=$?
  "$bin" --version 2>/dev/null | grep -q "^scu "      # 版本号，stdout 一行
  rc_version=$?
  TMPDIR="$tmp/" "$bin" dump >/dev/null 2>&1          # 用法错误，退出码 64
  rc1=$?
  TMPDIR="$tmp/" "$bin" dump --pid 1 --depth 999 >/dev/null 2>&1   # 深度越界，退出码 64
  rc2=$?
  TMPDIR="$tmp/" "$bin" permissions >/dev/null 2>&1   # 0 或 2，均须清理
  rc3=$?
  leaked="$(ls "$tmp" | wc -l | tr -d ' ')"
  rm -rf "$tmp"
  if [ "$rc_help" -ne 0 ] || [ "$rc_version" -ne 0 ]; then
    echo "   ❌ --help/--version 失败：help=${rc_help} version=${rc_version}"
    fail=1
  elif [ "$rc1" -ne 64 ] || [ "$rc2" -ne 64 ] || { [ "$rc3" -ne 0 ] && [ "$rc3" -ne 2 ]; }; then
    echo "   ❌ 退出码不符：dump=${rc1} depth=${rc2} permissions=${rc3}"
    fail=1
  elif [ "$leaked" -ne 0 ]; then
    echo "   ❌ 泄漏 ${leaked} 个临时目录"
    fail=1
  else
    echo "   ✅ help/version、退出码符合预期，无泄漏（permissions 退出码 ${rc3}）"
  fi
else
  echo "   跳过（前面的步骤已失败）"
fi

# MCP 冒烟：stdout 只有协议消息；正常退出与被 SIGKILL 都不遗留 socket 目录。
# SIGKILL 时 scu 自己的清理不会运行，由 scu-native 在发现连接断开后回收目录。
# TMPDIR 由 NativeClient 显式遵从（FileManager.temporaryDirectory 不一定遵从），
# 因此这里的"无泄漏"是有意义的检查，而不是空检查。
if [ "$fail" -eq 0 ]; then
  bin="$(swift build --show-bin-path)/scu"
  tmp="$(mktemp -d /tmp/scu-smoke.XXXXXX)"
  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}'
  apps='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}'

  out="$(printf '%s\n%s\n' "$init" "$apps" | TMPDIR="$tmp/" "$bin" mcp 2>/dev/null)"
  rc4=$?
  nonjson="$(printf '%s\n' "$out" | python3 -c 'import sys,json
bad=0
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try:
        if json.loads(l).get("jsonrpc")!="2.0": bad+=1
    except Exception: bad+=1
print(bad)')"
  leaked_exit="$(ls "$tmp" | wc -l | tr -d ' ')"

  mkfifo "$tmp/in"
  mkdir "$tmp/k"
  TMPDIR="$tmp/k/" "$bin" mcp <"$tmp/in" >/dev/null 2>&1 &
  mpid=$!
  exec 9>"$tmp/in"
  printf '%s\n' "$apps" >&9
  sleep 1.5
  during="$(ls "$tmp/k" | wc -l | tr -d ' ')"
  kill -KILL "$mpid" 2>/dev/null
  wait "$mpid" 2>/dev/null
  exec 9>&-
  sleep 1.5
  leaked_kill="$(ls "$tmp/k" | wc -l | tr -d ' ')"
  rm -rf "$tmp"

  if [ "$rc4" -ne 0 ] || ! printf '%s' "$out" | grep -q '"name":"scu"' || [ "$nonjson" -ne 0 ]; then
    echo "   ❌ MCP 握手失败或 stdout 混入非协议输出（退出码 ${rc4}，非协议行 ${nonjson}）"
    fail=1
  elif [ "$leaked_exit" -ne 0 ]; then
    echo "   ❌ MCP 正常退出后泄漏 ${leaked_exit} 个临时目录"
    fail=1
  elif [ "$during" -ne 1 ]; then
    echo "   ❌ 被杀路径的观测前提不成立：运行中应有 1 个 socket 目录，实际 ${during}（检查本身无效）"
    fail=1
  elif [ "$leaked_kill" -ne 0 ]; then
    echo "   ❌ MCP 被 SIGKILL 后泄漏 ${leaked_kill} 个临时目录"
    fail=1
  else
    echo "   ✅ MCP：握手正常、stdout 纯协议、正常退出与 SIGKILL 均无泄漏"
  fi
fi

echo
if [ "$fail" -eq 0 ]; then echo "✅ 全部通过"; else echo "❌ 有检查失败"; fi
exit $fail
