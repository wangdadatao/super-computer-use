#!/usr/bin/env bash
# 复现"访达大目录（列表视图）读树耗时"：建一个含 N 个文件的临时目录，在访达里以列表视图打开，
# 用 scu dump 计时，然后关闭窗口并删除目录。
#
# 会短暂改变桌面状态（多开一个访达窗口），退出时（含中断）由 trap 恢复。
# 需要：辅助功能权限（`scu permissions` 为已授予）、访达的自动化权限（首次可能弹窗）。
#
# 用法：scripts/bench_finder_list.sh [文件数，默认 1500] [scu 可执行文件，默认当前构建产物]
# 可传入旧版 scu 对比（旧版需与其 scu-native 在同一目录）。
# 记录见 verification/2026-10-17-read-latency.md。

set -uo pipefail
cd "$(dirname "$0")/.."

n="${1:-1500}"
bin="${2:-$(swift build --show-bin-path)/scu}"
dir="$(mktemp -d /tmp/scu-bigfolder.XXXXXX)"
before="$(osascript -e 'tell application "Finder" to count of Finder windows')"

cleanup() {
  # 只关闭比开始时多出来的窗口，不动用户原有的窗口。
  after="$(osascript -e 'tell application "Finder" to count of Finder windows' 2>/dev/null || echo "$before")"
  if [ "${after:-0}" -gt "$before" ]; then
    osascript -e 'tell application "Finder" to close front Finder window' >/dev/null 2>&1
  fi
  rm -rf "$dir"
}
trap cleanup EXIT INT TERM

for i in $(seq 1 "$n"); do : > "$dir/file_$i.txt"; done

osascript >/dev/null <<OSA
tell application "Finder"
  open (POSIX file "$(cd "$dir" && pwd -P)" as alias)
  delay 1
  set current view of front window to list view
  delay 2
end tell
OSA

pid="$(pgrep -x Finder | head -1)"
for i in 1 2 3; do
  s=$(date +%s.%N)
  "$bin" dump --pid "$pid" --depth 24 --budget-ms 60000 >/tmp/bench_dump.out 2>/tmp/bench_dump.err
  e=$(date +%s.%N)
  echo "第 $i 次：$(echo "$e - $s" | bc) 秒，$(grep -c '' /tmp/bench_dump.out) 个元素，$(grep -o '已截断' /tmp/bench_dump.err | head -1)"
done
