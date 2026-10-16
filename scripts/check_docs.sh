#!/usr/bin/env bash
# SCU 文档库结构与图表校验。
#
# 用法：scripts/check_docs.sh
#
# 检查项：
#   1. 命名规范（文件与目录小写 snake_case）
#   2. 每篇唯一 H1
#   3. 全部 Markdown 链接可达
#   4. 分类目录路由完整（每个文件在且仅在其分类的 index.md 中列出）
#   5. 根目录路由全部分类
#   6. ADR 必备字段齐全
#   7. mermaid 图型合法（结构检查）
#   8. mermaid 实际渲染（需 mmdc，缺失时跳过并提示）
#
# 退出码：0 全部通过，1 存在问题。

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "── 结构与链接检查 ──"
python3 - <<'PY' || fail=1
import os, re, sys

files = [os.path.join(dp, f) for dp, _, fn in os.walk("docs") for f in fn if f.endswith(".md")]
files += ["README.md", "AGENTS.md"]
errors, mermaid = [], 0
name_re = re.compile(r"^[a-z][a-z0-9_]*\.md$")
diagram_re = re.compile(r"^(flowchart|graph|stateDiagram-v2|sequenceDiagram|erDiagram|classDiagram)\b")

for p in files:
    b = os.path.basename(p)
    if (p.startswith("docs/")) and not name_re.match(b):
        errors.append(f"命名不合规: {p}")
    txt = open(p, encoding="utf-8").read()
    body = re.sub(r"```.*?```", "", txt, flags=re.S)
    if len(re.findall(r"^# .+$", body, re.M)) != 1:
        errors.append(f"H1 数量异常: {p}")
    for m in re.finditer(r"\[([^\]]+)\]\(([^)#\s]+)(?:#[^)]*)?\)", body):
        t = m.group(2)
        if t.startswith(("http", "mailto")):
            continue
        if not os.path.exists(os.path.normpath(os.path.join(os.path.dirname(p), t))):
            errors.append(f"失效链接: {p} -> {t}")
    for blk in re.findall(r"```mermaid\n(.*?)```", txt, re.S):
        mermaid += 1
        first = blk.strip().splitlines()[0].strip()
        if not diagram_re.match(first):
            errors.append(f"mermaid 图型可疑: {p} -> {first}")

for d in sorted(os.listdir("docs")):
    full = os.path.join("docs", d)
    if not os.path.isdir(full):
        continue
    idx = os.path.join(full, "index.md")
    if not os.path.exists(idx):
        errors.append(f"分类缺少 index.md: {full}")
        continue
    t = open(idx, encoding="utf-8").read()
    for f in sorted(os.listdir(full)):
        if f.endswith(".md") and f != "index.md" and f"({f})" not in t:
            errors.append(f"分类目录漏列: {d}/{f}")

root = open("docs/index.md", encoding="utf-8").read()
for d in sorted(os.listdir("docs")):
    if os.path.isdir(os.path.join("docs", d)) and f"({d}/index.md)" not in root:
        errors.append(f"根目录未路由分类: {d}")

for f in sorted(os.listdir("docs/decisions")):
    if not f.startswith("adr_"):
        continue
    t = open(f"docs/decisions/{f}", encoding="utf-8").read()
    for need in ["状态**：", "日期**：", "## 背景", "## 决策", "## 取舍", "## 后果", "## 相关文档"]:
        if need not in t:
            errors.append(f"ADR 缺字段 {need}: {f}")

print(f"   扫描 {len(files)} 个文件，{mermaid} 张 mermaid 图")
if errors:
    print(f"   ❌ {len(errors)} 个问题：")
    for e in errors[:60]:
        print(f"      {e}")
    sys.exit(1)
print("   ✅ 通过")
PY

echo "── mermaid 渲染检查 ──"
if command -v mmdc >/dev/null 2>&1; then
  # puppeteer 若使用缓存的 Chrome，需要通过环境变量指路。
  # mmdc 默认不去找缓存，会尝试下载，在无网或沙箱环境下会卡住。
  if [ -z "${PUPPETEER_EXECUTABLE_PATH:-}" ]; then
    cached="$(ls -d "$HOME"/.cache/puppeteer/chrome/*/chrome-mac-*/"Google Chrome for Testing.app"/Contents/MacOS/"Google Chrome for Testing" 2>/dev/null | head -1)"
    if [ -n "$cached" ]; then
      export PUPPETEER_EXECUTABLE_PATH="$cached"
      echo "   使用缓存 Chrome：$cached"
    fi
  fi
  for f in $(grep -rl '```mermaid' docs || true); do
    if mmdc -i "$f" -o /tmp/scu-mmd-check.md >/dev/null 2>&1; then
      echo "   ✅ $f"
    else
      echo "   ❌ $f 渲染失败"
      fail=1
    fi
  done
  rm -f /tmp/scu-mmd-check*.svg /tmp/scu-mmd-check.md
else
  echo "   ⚠️  未安装 mmdc，跳过渲染检查。安装：npm i -g @mermaid-js/mermaid-cli"
fi

exit $fail
