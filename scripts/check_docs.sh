#!/usr/bin/env bash
# SCU 文档库结构与图表校验。
#
# 用法：scripts/check_docs.sh
#
# 检查项：
#   1. 命名规范（`docs/` 下的 .md 文件名小写 snake_case；目录名与 verification/ 不检查）
#   2. 每篇唯一 H1（根目录的 docs_audit_*.md 历史审计报告豁免 H1 与术语检查，只查链接）
#   3. 全部 Markdown 链接可达，**含 #锚点**
#   4. 分类目录路由完整（每个文件必须在其分类的 index.md 中出现；不检查是否只出现在这一处）
#   5. 根目录路由全部分类
#   6. ADR 必备字段齐全
#   7. 术语一致性：不应残留已废弃的旧术语
#   8. mermaid 图型合法（结构检查）
#   9. mermaid 实际渲染（需 mmdc，缺失时跳过并提示）
#  10. 代码侧 @project-doc 锚点：路径存在、目标是显式 <a id> ID、格式合规；显式 ID 不重复
#
# 扫描范围：docs/、verification/、仓库根的 *.md（含审计报告）。
#
# 退出码：0 全部通过，1 存在问题。

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "── 结构与链接检查 ──"
python3 - <<'PY' || fail=1
import os, re, sys, unicodedata

roots = ["docs", "verification"]
files = []
for r in roots:
    if os.path.isdir(r):
        files += [os.path.join(dp, f) for dp, _, fn in os.walk(r)
                  for f in fn if f.endswith(".md")]
root_md = [f for f in sorted(os.listdir(".")) if f.endswith(".md")]
files += root_md

# 一次性审计报告属于历史产物：它引用旧术语、且会转述其他文档的链接。
# 对它只做链接可达性检查，不做命名 / H1 / 术语一致性检查。
HISTORICAL = {f for f in root_md if f.startswith("docs_audit_")}

errors, mermaid = [], 0
name_re = re.compile(r"^[a-z][a-z0-9_]*\.md$")
diagram_re = re.compile(r"^(flowchart|graph|stateDiagram-v2|sequenceDiagram|erDiagram|classDiagram)\b")

def strip_code(text):
    """去掉围栏代码块与行内代码，避免引用文本里的链接被当成真链接。"""
    out = re.sub(r"```.*?```", "", text, flags=re.S)
    return re.sub(r"`[^`\n]*`", "", out)

def slug(heading):
    """按 GitHub 风格的标题 slug 规则生成锚点。"""
    s = heading.strip().lower()
    s = re.sub(r"[`*]", "", s)                      # 去行内标记
    out = []
    for ch in s:
        if ch.isalnum() or ch in "-_":
            out.append(ch)
        elif ch.isspace():
            out.append("-")
        # 其余标点（含全角）丢弃
    return "".join(out)

# 预算每篇文档的锚点集合
anchors = {}
explicit = {}
for p in files:
    txt = open(p, encoding="utf-8").read()
    body = strip_code(txt)
    anchors[os.path.normpath(p)] = {
        slug(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+)$", body, re.M)
    }
    # 显式 HTML ID（<a id="x"></a>）：代码锚点只允许指向这类稳定 ID，不指向标题 slug。
    ids = re.findall(r'<a id="([^"]+)"></a>', body)
    explicit[os.path.normpath(p)] = set(ids)
    anchors[os.path.normpath(p)] |= set(ids)
    for dup in {i for i in ids if ids.count(i) > 1}:
        errors.append(f"重复的显式章节 ID {dup}: {p}")
    for bad in ids:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", bad):
            errors.append(f"显式章节 ID 不符合 snake_case {bad}: {p}")

for p in files:
    b = os.path.basename(p)
    historical = b in HISTORICAL
    if p.startswith("docs/") and not name_re.match(b):
        errors.append(f"命名不合规: {p}")
    txt = open(p, encoding="utf-8").read()
    body = strip_code(txt)
    if not historical and len(re.findall(r"^# .+$", body, re.M)) != 1:
        errors.append(f"H1 数量异常: {p}")

    for m in re.finditer(r"\[([^\]]+)\]\(([^)\s]+)\)", body):
        target = m.group(2)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        path, _, anchor = target.partition("#")
        base = os.path.normpath(os.path.join(os.path.dirname(p), path)) if path \
               else os.path.normpath(p)
        if path and not os.path.exists(base):
            errors.append(f"失效链接: {p} -> {target}")
            continue
        if anchor:
            have = anchors.get(base)
            if have is None and os.path.exists(base):
                have = set()
            if have is not None and anchor.lower() not in have:
                errors.append(f"失效锚点: {p} -> {target}")

    for blk in re.findall(r"```mermaid\n(.*?)```", txt, re.S):
        mermaid += 1
        first = blk.strip().splitlines()[0].strip()
        if not diagram_re.match(first):
            errors.append(f"mermaid 图型可疑: {p} -> {first}")

    # 已废弃术语（审计 N-03）。历史产物豁免。
    if not historical:
        for bad, why in [("指纹", "旧术语，应为「候选键/匹配键」或「结构摘要」"),
                         ("五态", "匹配结果已改为四态")]:
            for i, line in enumerate(body.splitlines(), 1):
                if bad in line and "不应残留" not in line:
                    errors.append(f"废弃术语「{bad}」({why}): {p}:{i}")

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

# 代码侧 @project-doc 锚点：路径存在、ID 是显式 ID、格式合规。
code_anchors = 0
for top in ("Sources", "Tests", "scripts"):
    for dp, _, fn in os.walk(top):
        for f in fn:
            if not f.endswith((".swift", ".sh")) or f == "check_docs.sh":
                continue
            cp = os.path.join(dp, f)
            for i, line in enumerate(open(cp, encoding="utf-8"), 1):
                if "@project-doc" not in line:
                    continue
                m = re.search(r"@project-doc\s+(\S+)", line)
                code_anchors += 1
                if not m:
                    errors.append(f"锚点缺少目标: {cp}:{i}")
                    continue
                target = m.group(1)
                path, _, sid = target.partition("#")
                if not re.fullmatch(r"docs/[a-z0-9_/]+\.md", path) or not re.fullmatch(r"[a-z][a-z0-9_]*", sid):
                    errors.append(f"锚点格式不合规: {cp}:{i} -> {target}")
                elif not os.path.exists(path):
                    errors.append(f"锚点文档不存在: {cp}:{i} -> {target}")
                elif sid not in explicit.get(os.path.normpath(path), set()):
                    errors.append(f"锚点 ID 不存在（须是 <a id> 显式 ID）: {cp}:{i} -> {target}")

print(f"   扫描 {len(files)} 个文件，{mermaid} 张 mermaid 图，{code_anchors} 个代码锚点")
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
      echo "   使用缓存 Chrome"
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
