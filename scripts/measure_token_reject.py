#!/usr/bin/env python3
"""测量令牌的拒绝行为与重读成本（ADR-0013 的 2026-10-19 追加记录第 3 条）。

四项指标，全部在受控夹具 `scu-fixture` 上、经 `scu mcp --actions` 驱动：

  A 无外部变化时重复动作 —— 误拒率。期望 0；不为 0 是缺陷。
  B 外部值变化后动作     —— 误拒率。期望 0：路径与标题未变，取值变化不该让目标失效。
  C 外部结构变化后动作   —— 保守拒绝率。按 ADR-0015 的取舍预期被拒；这是代价，不是缺陷。
  D 自身点击会改值的按钮 —— 令牌失效与重读次数，即"每动一步要重读几次"的成本。

为什么要两个会话（A、B）：一个 DesktopSession 的令牌看不到另一个会话造成的界面变化，
所以 B 的改动对 A 而言等同于"应用自己变了"。这也正是 ADR-0015 的路径核对要处理的情形。

需要辅助功能权限（先跑 `scu permissions`）。运行时会短暂出现一个夹具窗口，不抢焦点。

用法：
  scripts/measure_token_reject.py [--rounds N]

退出码：0 成功；1 失败；2 缺辅助功能权限。
结果建议写入 verification/YYYY-MM-DD-token-reject-rate.md，脚本会打印可直接粘贴的表格。
"""

import argparse
import json
import os
import platform
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TOKEN_RE = re.compile(r"令牌\s+(\S+)")
HANDLE_RE = re.compile(r"^\[[^\]\s#]+#(\d+)\]\s+\"((?:[^\"\\]|\\.)*)\"")
EFFECT_RE = re.compile(r"effect:\s*(.*)")
CODE_RE = re.compile(r"^\[([a-z_]+)\]")

TARGETS = ("Increment", "NoOp", "AddRow")


class MeasurementError(RuntimeError):
    pass


class Mcp:
    """一个 `scu mcp --actions` 进程：一条连接对应一个 DesktopSession。"""

    def __init__(self, scu_path):
        self.proc = subprocess.Popen(
            [scu_path, "mcp", "--actions"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
        )
        self.next_id = 0

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        try:
            self.proc.stdin.write(json.dumps(message) + "\n")
            self.proc.stdin.flush()
        except BrokenPipeError as e:
            raise MeasurementError("scu mcp 已退出，无法写入请求") from e
        line = self.proc.stdout.readline()
        if not line:
            raise MeasurementError(f"scu mcp 没有应答（{method}），可能已崩溃")
        reply = json.loads(line)
        if "error" in reply:
            raise MeasurementError(f"{method} 返回 JSON-RPC 错误：{reply['error']}")
        return reply.get("result", {})

    def initialize(self):
        self.request("initialize", {"protocolVersion": "2025-06-18"})

    def tool(self, name, arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = "".join(part.get("text", "") for part in result.get("content", []))
        return bool(result.get("isError")), text

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def swift_bin_dir():
    out = subprocess.run(
        ["swift", "build", "--show-bin-path"], cwd=ROOT, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if out.returncode != 0:
        raise MeasurementError("swift build --show-bin-path 失败：\n" + out.stderr.strip())
    path = out.stdout.strip()
    if not path:
        raise MeasurementError("swift build --show-bin-path 没有输出路径")
    return path


def list_apps(mcp):
    _, text = mcp.tool("list_apps", {})
    apps = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0].strip().isdigit():
            apps.append((int(parts[0]), parts[1], parts[2] if len(parts) > 2 else "-"))
    return apps


def wait_fixture(mcp, fixture, stderr_file, deadline=30.0):
    """等夹具出现在 list_apps 里。夹具提前退出或始终没出现时，把可诊断的信息一起报出来。"""
    start = time.time()
    announced = start
    last_apps = []
    while time.time() - start < deadline:
        last_apps = list_apps(mcp)
        for pid, name, _ in last_apps:
            if "fixture" in name.lower():
                return pid
        if fixture.poll() is not None:
            raise MeasurementError(
                f"夹具进程已退出（退出码 {fixture.returncode}）。{fixture_stderr(stderr_file)}")
        if time.time() - announced >= 5:
            announced = time.time()
            print("  仍在等待夹具窗口出现…", flush=True)
        time.sleep(0.3)
    names = [name for _, name, _ in last_apps[-5:]]
    raise MeasurementError(
        f"没有在 list_apps 里看到 scu-fixture（夹具 pid {fixture.pid} 仍在运行：{fixture.poll() is None}）。"
        f"最近看到的应用：{names}。{fixture_stderr(stderr_file)}")


def fixture_stderr(handle):
    if handle is None:
        return ""
    handle.flush()
    handle.seek(0)
    text = handle.read().strip()
    return f"夹具 stderr：{text[-800:]}" if text else "夹具没有输出 stderr"


def read_state(mcp, pid):
    """返回 (令牌, {标题: 句柄})。标题在夹具上唯一。"""
    is_error, text = mcp.tool("get_ax_state", {"pid": pid, "max_depth": 12, "max_elements": 2000})
    if is_error:
        raise MeasurementError("get_ax_state 失败：" + text.splitlines()[0])
    token_match = TOKEN_RE.search(text)
    if not token_match:
        raise MeasurementError("get_ax_state 的输出里没有令牌：\n" + text[:400])
    handles = {}
    for line in text.splitlines():
        found = HANDLE_RE.search(line)
        if found:
            title = found.group(2).replace('\\"', '"').replace("\\\\", "\\")
            handles.setdefault(title, int(found.group(1)))
    missing = [t for t in TARGETS if t not in handles]
    if missing:
        raise MeasurementError(f"夹具里找不到控件：{missing}（句柄：{handles}）")
    return token_match.group(1), handles


def stable_state(mcp, pid, tries=60):
    """等到结构连续两次一致（同一令牌），避免把启动期的变化当成界面状态。"""
    previous = None
    stable = 0
    for _ in range(tries):
        token, handles = read_state(mcp, pid)
        stable = stable + 1 if token == previous else 1
        previous = token
        if stable >= 2:
            return token, handles
        time.sleep(0.2)
    raise MeasurementError("界面在等待时间内没有稳定")


def click(mcp, token, handle):
    """返回 {"error": code} 或 {"flags": {字段: 值}, "text": 原文}。"""
    is_error, text = mcp.tool("click", {"token": token, "handle": handle})
    if is_error:
        code = CODE_RE.match(text)
        return {"error": code.group(1) if code else "unknown", "text": text}
    match = EFFECT_RE.search(text)
    if not match:
        raise MeasurementError("click 的输出里没有 effect 行：\n" + text[:400])
    flags = dict(item.split("=", 1) for item in match.group(1).split() if "=" in item)
    return {"flags": flags, "text": text}


def phase_a(mcp, pid, rounds):
    """无外部变化时的重复动作：令牌应一直有效。"""
    token, handles = stable_state(mcp, pid)
    rejects, no_ops, errors = [], 0, []
    for _ in range(rounds):
        result = click(mcp, token, handles["NoOp"])
        if "error" in result:
            rejects.append(result["error"])
            token, handles = stable_state(mcp, pid)
            continue
        if result["flags"].get("noOpSuspected") == "true":
            no_ops += 1
        if result["text"].find("旧令牌已作废") >= 0:
            errors.append("noop_invalidated_token")
            token, handles = stable_state(mcp, pid)
    return {"rounds": rounds, "rejects": rejects, "no_ops": no_ops, "errors": errors}


def phase_b(a, b, pid, rounds):
    """外部值变化（标签文字）后动作：路径未变，不该被拒。"""
    rejects, errors = [], []
    for _ in range(rounds):
        token, handles = stable_state(a, pid)
        token_b, handles_b = stable_state(b, pid)
        changed = click(b, token_b, handles_b["Increment"])
        if "error" in changed:
            errors.append("b_increment:" + changed["error"])
        result = click(a, token, handles["NoOp"])
        if "error" in result:
            rejects.append(result["error"])
            continue
        # 值变了，A 的令牌按设计会失效；这里只记录，不当作失败。
        if result["flags"].get("treeChanged") not in ("true", None):
            errors.append("value_change_not_observed:" + str(result["flags"].get("treeChanged")))
    return {"rounds": rounds, "rejects": rejects, "errors": errors}


def phase_c(a, b, pid, rounds):
    """外部结构变化（加兄弟）后动作：ADR-0015 的取舍，预期被拒。"""
    outcomes, errors = [], []
    for _ in range(rounds):
        token, handles = stable_state(a, pid)
        token_b, handles_b = stable_state(b, pid)
        added = click(b, token_b, handles_b["AddRow"])
        if "error" in added:
            errors.append("b_addrow:" + added["error"])
            continue
        result = click(a, token, handles["NoOp"])
        if "error" in result:
            outcomes.append(result["error"])
        else:
            outcomes.append("not_rejected")
    return {"rounds": rounds, "outcomes": outcomes, "errors": errors}


def phase_d(mcp, pid, rounds):
    """自身点击会改值的按钮：记录令牌失效与随之而来的重读。"""
    invalidated, still_valid, errors = 0, 0, []
    for _ in range(rounds):
        token, handles = stable_state(mcp, pid)
        first = click(mcp, token, handles["Increment"])
        if "error" in first:
            errors.append("increment:" + first["error"])
            continue
        if "旧令牌已作废" in first["text"]:
            invalidated += 1
        second = click(mcp, token, handles["Increment"])
        if "error" in second:
            if second["error"] != "stale_snapshot":
                errors.append("second_click:" + second["error"])
        else:
            still_valid += 1
    return {
        "rounds": rounds, "invalidated": invalidated, "still_valid": still_valid,
        "errors": errors, "rereads": rounds,
    }


def main():
    parser = argparse.ArgumentParser(description="测量令牌拒绝行为与重读成本（需辅助功能权限）。")
    parser.add_argument("--rounds", type=int, default=8, help="每项的轮数，默认 8")
    parser.add_argument("--json", action="store_true", help="额外输出原始 JSON")
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds 必须 ≥ 1")

    bin_dir = swift_bin_dir()
    scu = os.path.join(bin_dir, "scu")
    fixture_bin = os.path.join(bin_dir, "scu-fixture")
    if not os.access(scu, os.X_OK) or not os.access(fixture_bin, os.X_OK):
        raise MeasurementError(f"找不到构建产物：{scu} 或 {fixture_bin}，先 swift build")

    permission = subprocess.run([scu, "permissions"], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if permission.returncode == 2:
        print(f"没有辅助功能权限：{permission.stdout.strip()}")
        print("给启动本脚本的宿主授予辅助功能权限后重试，见 docs/operations/permissions.md。")
        return 2
    if permission.returncode != 0:
        raise MeasurementError(f"scu permissions 失败（退出码 {permission.returncode}）：{permission.stdout.strip()}")

    fixture_stderr_file = tempfile.TemporaryFile(mode="w+")
    fixture = subprocess.Popen(
        [fixture_bin], stdout=subprocess.DEVNULL, stderr=fixture_stderr_file)
    a = b = None
    try:
        a = Mcp(scu)
        b = Mcp(scu)
        a.initialize()
        b.initialize()
        pid = wait_fixture(a, fixture, fixture_stderr_file)
        print(f"夹具 pid={pid}，每项 {args.rounds} 轮。窗口会在结束时关闭。\n", flush=True)

        result_a = phase_a(a, pid, args.rounds)
        print(f"A 无外部变化：{len(result_a['rejects'])}/{args.rounds} 次被拒", flush=True)
        result_b = phase_b(a, b, pid, args.rounds)
        print(f"B 外部值变化：{len(result_b['rejects'])}/{args.rounds} 次被拒", flush=True)
        result_c = phase_c(a, b, pid, args.rounds)
        rejected_c = sum(1 for x in result_c["outcomes"] if x == "stale_snapshot")
        print(f"C 外部结构变化：{rejected_c}/{args.rounds} 次被拒", flush=True)
        result_d = phase_d(a, pid, args.rounds)
        print(f"D 自身改值点击：{result_d['invalidated']}/{args.rounds} 次令牌失效", flush=True)
    finally:
        for client in (a, b):
            if client is not None:
                client.close()
        if fixture.poll() is None:
            fixture.terminate()
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.kill()
        fixture_stderr_file.close()

    commit = subprocess.run(
        ["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    commit = commit.stdout.strip() if commit.returncode == 0 else "-"
    host = subprocess.run(
        ["ps", "-o", "comm=", "-p", str(os.getppid())], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    host = host.stdout.strip() or "未知"
    rounds = args.rounds
    c_rejected = sum(1 for x in result_c["outcomes"] if x == "stale_snapshot")
    c_other = [x for x in result_c["outcomes"] if x not in ("stale_snapshot", "not_rejected")]
    summary = {
        "environment": {
            "date": datetime.now().astimezone().isoformat(timespec="seconds"),
            "commit": commit,
            "macos": platform.mac_ver()[0],
            "machine": platform.machine(),
            "host_process": host,
            "rounds": rounds,
        },
        "a_no_external_change": result_a,
        "b_external_value_change": result_b,
        "c_external_structural_change": result_c,
        "d_self_click_invalidation": result_d,
    }
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))

    print("\n=== 可直接粘贴到 verification 记录的表格 ===")
    print("| 指标 | 构造 | 轮数 | 结果 |")
    print("| --- | --- | --- | --- |")
    print(f"| A 无外部变化时重复动作 | 同一令牌连续点击 NoOp | {rounds} | "
          f"被拒 {len(result_a['rejects'])} 次；noOpSuspected=true {result_a['no_ops']}/{rounds} |")
    print(f"| B 外部值变化后动作 | 另一会话点击 Increment 改标签文字，再点 NoOp | {rounds} | "
          f"被拒 {len(result_b['rejects'])} 次 |")
    print(f"| C 外部结构变化后动作 | 另一会话点击 AddRow 加兄弟，再点 NoOp | {rounds} | "
          f"被拒 {c_rejected} 次（{c_rejected * 100 // rounds}%）"
          + (f"，其他错误 {c_other}" if c_other else "") + " |")
    print(f"| D 自身点击后的令牌失效 | 用同一令牌连续点击 Increment 两次 | {rounds} | "
          f"第一次点击后令牌失效 {result_d['invalidated']} 次；第二次仍通过 {result_d['still_valid']} 次；"
          f"重读 {result_d['rereads']} 次 |")

    errors = result_a["errors"] + result_b["errors"] + result_c["errors"] + result_d["errors"]
    if errors:
        print("\n⚠️ 非预期错误：")
        for error in errors:
            print("   -", error)
        return 1

    print("\nA、B 的拒绝才是误拒；C 的拒绝是 ADR-0015 的保守取舍（路径上的兄弟数变了），")
    print("比例高不构成缺陷，但说明\"界面自己变了\"时调用方会被要求重读。D 是每步的固定成本。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except MeasurementError as error:
        print(f"失败：{error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
