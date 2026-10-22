# SuperComputerUse (SCU)

An MCP server that lets AI agents read and operate macOS app interfaces — and reports whether each
action actually took effect.

[中文](README.md) · [Engineering docs](docs/index.md) · [Agent guide](skills/scu/SKILL.md)

> Early-stage software (0.4.0). Source builds are supported. No prebuilt binaries are published yet:
> the release zip is ad-hoc signed and not notarized, so public download would be blocked by Gatekeeper.

## The problem

Desktop automation can click things, but usually cannot answer a more basic question: **did the click
land on the element I meant, and did it do anything?**

Three silent failures follow:

- **Stale addressing** — an element id from the previous read now points at a different control.
- **No-op actions** — the event was delivered but nothing happened, or focus went to another window.
- **No verification** — nothing checks that the observed result matches the intended one.

SCU makes these protocol concerns: every read issues a snapshot token, stale tokens are rejected by
the server, and every action returns a machine-checkable effect summary that asks the caller to re-read.

## What it does today

| Works | Not implemented |
| --- | --- |
| Read the accessibility tree of running macOS apps as a text element table | Web DOM / tab semantics (browser surface is a roadmap item) |
| Launch and activate apps; enumerate and target windows | Right-click, long press, IME input (unverified) |
| Click elements (`AXPress`), type text, send keys, set values | Per-action approval, leases, audit log |
| Screenshot a target window with element labels; coordinate click / scroll / drag | Code mode (`js` tools) |
| Effect summaries: did the UI change, was the action a probable no-op | Linux / Windows |

**Read-only by default.** `scu mcp` exposes only read tools; actions require `scu mcp --actions`.
An optional per-connection app allowlist (`--allow-app`) narrows the target scope.

## Quick start

Requires macOS 14.4+ and Swift 6.x (Xcode command line tools). No third-party dependencies.

```bash
git clone https://github.com/wangdadatao/super-computer-use.git SuperComputerUse
cd SuperComputerUse
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
mkdir -p ~/bin/scu && cp "$BIN/scu" "$BIN/scu-native" ~/bin/scu/
~/bin/scu/scu permissions        # exit code 2 = Accessibility permission not granted yet
```

`scu` looks for `scu-native` in its own directory; keep the two together. Granting Accessibility and
Screen Recording must be done by a human in System Settings — see
[docs/operations/permissions.md](docs/operations/permissions.md).

Add it to an MCP host (Cursor, Claude Desktop, …):

```json
{
  "mcpServers": {
    "scu": {
      "command": "/Users/<you>/bin/scu/scu",
      "args": ["mcp", "--actions", "--allow-app", "com.apple.TextEdit"]
    }
  }
}
```

## How it behaves

- **Accessibility first, coordinates as fallback.** Coordinate actions stay bound to the window that
  was captured.
- **Positional handles + snapshot tokens.** Element handles are valid only within one read; a
  cross-snapshot handle registry is intentionally not implemented (the verification did not hold).
- **Deny-by-category policy.** Terminals, script runners, password managers and System Settings are
  refused as action targets.
- **Two processes.** `scu` (MCP/protocol) launches `scu-native` (AX, capture, input) and talks to it
  over a local socket.

Thirty ADRs record the trade-offs in [docs/decisions/index.md](docs/decisions/index.md). Observations
about reference implementations are registered with sources in
[verification/external-sources.md](verification/external-sources.md).

## Status

Version 0.4.0 (2026-10-21). Verified so far:

- 153 automated tests, plus docs structure/link/anchor checks and mermaid rendering;
- snapshot tokens and effect summaries hold on a controlled fixture (0/8 false rejections);
- real-app runs on NetEase Cloud Music (CEF), TextEdit multi-window, Calculator and Edge;
- 6 real tasks: 5 passed, 1 partially passed.

Known gaps: no browser surface, heuristic action convergence can miss changes after two seconds, no
code mode, no per-action approvals, and actions invoked through a host (Cursor/Claude) are not yet
verified end to end.

See [the current stage in docs/index.md](docs/index.md) and [verification/](verification/README.md).
Anything not listed as implemented is design intent, not verified behavior.

## Contributing

Run `scripts/check.sh` before committing (docs + format + build + tests + CLI/MCP smoke). See
[CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately per [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).

## Independence

SCU is an independent project, not affiliated with or endorsed by OpenAI, xAI or Anysphere. Product
names mentioned in the docs belong to their owners and only mark where design inspiration came from;
those conclusions come from external observation of publicly distributed artifacts, with no code copied.
