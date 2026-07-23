<!-- doc-tier: human | canonical-for: claude-code-onramp | budget: 1600tok -->
# Barkpark in Claude Code

Give your Claude Code agent a real task board — lifecycle, priorities, and an
atomic claim/close contract built for concurrent workers — as first-class MCP
tools. Two minutes, three steps.

## 1. Install the `bp` CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

The installer drops `bp` in `/usr/local/bin`, or falls back to `~/.local/bin`
when that isn't writable — and prints a `PATH` hint if the dir it chose isn't on
your `PATH`. If `bp` isn't found afterward, add the fallback and restart your
shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 2. Connect and authenticate

`bp` needs a Barkpark to talk to and a token to write with. Both journeys —
local admin token and Barkpark Cloud auth-tunnel login — live in one place:

See [Agent Onramps](AGENT-ONRAMPS.md) for AUTH (local + cloud) and the
CREATE-QUICKSTART (schema · doc · task · paper). Quick check once connected:

```bash
bp task ready     # empty list = connected, no open work
```

## 3. Register the MCP server

`bp mcp serve` runs a stdio MCP server that turns the CLI's capability manifest
into a tool catalog Claude Code calls directly — claim, read the brief, close
with epoch-CAS, never touching a shell. Register it one of two ways.

**A — CLI (quickest):**

```bash
claude mcp add --scope project --transport stdio \
  --env BARKPARK_API_URL=https://guerrilla.barkpark.cloud \
  --env 'BARKPARK_API_TOKEN=${BARKPARK_API_TOKEN}' \
  barkpark -- bp mcp serve
```

<!-- grammar verified 2026-07-10 against `claude mcp add --help` (Claude Code 2.1.206): `claude mcp add [options] <name> <commandOrUrl> [args...]`; options (--scope/--transport/--env) precede the name; `--` separates the server command -->

The `--env` pairs come **before** the server name, and the `--` separator is
required — everything after it is the server's own command line (`bp mcp serve`).
Keep the single quotes on the token pair: `--scope project` writes the committed
`.mcp.json`, so the stored value must stay the `${…}` placeholder (expanded from
your shell when the server starts) — never your literal token.

**B — committed `.mcp.json` (shared with the repo):**

Put this at the repo root so every teammate's Claude Code picks it up:

```json
{
  "mcpServers": {
    "barkpark": {
      "type": "stdio",
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${BARKPARK_API_TOKEN}"
      }
    }
  }
}
```

`${BARKPARK_API_TOKEN}` reads the token from your shell environment, so the
secret never lands in the committed file — set it in your profile
(`export BARKPARK_API_TOKEN=…`). Claude Code's env dialect is `${VAR}` and
`${VAR:-default}`. It is **not** the Cursor-only `${env:VAR}` form — that would
ship a literal string here.

**Scope precedence:** `local` > `project` > `user`. A `--scope local` server
(machine-private) overrides the committed `project` `.mcp.json`, which overrides
a `user`-scoped server. Pick `project` for the shared board; `local` to point
your own copy at a different Barkpark without touching the committed stanza.

Verify:

```bash
claude mcp list   # barkpark should appear, "connected"
```

A real live MCP client detects the emitted config: `claude mcp get barkpark`
reads the committed `.mcp.json` and reports it back byte-correct (command `bp`,
args `mcp serve`, both env vars). `scripts/onramp-live-client-smoke.sh` proves
this end-to-end against the `claude` CLI (manual, not CI).

### Retargeting

The `env` block is the whole instance override. `bp`'s environment layer sits
**above** the `~/.config/barkpark/` config file, so `BARKPARK_API_URL` +
`BARKPARK_API_TOKEN` in the stanza aim this server at any Barkpark — a hosted
instance, a teammate's, or `http://localhost:4000` — no matter what `bp setup`
saved.

## Claude Code on the web (cloud sessions)

Web sessions run in a fresh remote container, so this repo ships the wiring:
the committed `.mcp.json` (stanza B above) plus a `SessionStart` hook
(`scripts/ensure-bp.sh`) that installs the prebuilt `bp` binary when missing —
fail-soft, never blocks session start. Two things only the **environment
settings** (web UI) can provide:

- **Network egress allowlist** — add `guerrilla.barkpark.cloud` (and
  `github.com` for the installer); a blocked host fails with "Host not in
  allowlist".
- **Env vars** — `BARKPARK_API_URL` and `BARKPARK_API_TOKEN`. Get both from
  your instance page on the Cloud dashboard (**Connect agent**, owner/admin
  only) or `bp instance credentials <id>`; prefer a scoped token where you have
  one — [Token scoping](REMOTE.md#token-scoping).

Verify inside a session: `bp task ready` (empty list = connected, no open work).

## Teach Claude Code the task contract

The MCP tools carry the claim-first contract in their own descriptions, but you
can also teach it to the agent's system prompt so shelling out to `bp` follows
the same rules. Curl the ready-made snippet into place:

```bash
mkdir -p .claude
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/.claude/CLAUDE-BARKPARK.md \
  -o .claude/CLAUDE-BARKPARK.md
```

Then wire it into your project `CLAUDE.md` with an `@import` line (Claude Code
inlines it automatically):

```markdown
@.claude/CLAUDE-BARKPARK.md
```

From then on, "what should I work on?" means `bp task ready`, and finished work
is closed on the board — no markdown TODO lists.

## The tools

Eight curated task tools ship by default (`--tools tasks`), each carrying the
claim-first contract in its own description:

- **`task_ready`** — list ready (unblocked) tasks in priority order.
- **`task_next`** — atomically claim the next ready task; returns the brief and
  the claim epoch. Claim before working.
- **`task_show`** — fetch one task by id (brief, criteria, children).
- **`task_close`** — close a claimed task with the claim epoch (epoch-CAS); mark
  acceptance criteria met with evidence in the same atomic write.
- **`task_create`** — file new work (injects `kind` + `lifecycle_status`).
- **`task_prime`** — one-call rehydration for a resuming agent: in-progress
  claims (with close-ready epochs), ready head, recent events, counts.
- **`task_stamp`** — record evidence on ONE acceptance criterion mid-claim;
  `--met` needs non-empty evidence, `--miss` logs an honest attempt without
  flipping the lock (holder + epoch-gated).
- **`task_pulse`** — write the now-line and renew the lease in one write (no
  epoch arg — it bumps the claim epoch, so re-read it before the next close).

### `--tools all` (expert only)

Adding `"--tools", "all"` to `args` exposes **every** manifest verb as a tool
(`bp_<noun>_<verb>`), auto-derived from the live capabilities — a new plugin's
verbs appear with zero code changes. The full Barkpark manifest is ~107
commands, which floods the agent's tool list and dilutes tool selection. Keep
the default `tasks` unless you know exactly which handful you need.

## Troubleshooting

- **`bp: command not found`** — the installer put `bp` in `~/.local/bin`; make
  sure that's on your `PATH` and restart your shell (see step 1).
- **`barkpark` shows "failed" in `claude mcp list`** — a Barkpark whose Tasks
  plugin is disabled fails fast at startup with `manifest has no task.<verb>
  verb` on stderr. Point the stanza at a Barkpark with Tasks enabled.
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback in `.claude/CLAUDE-BARKPARK.md` (`bp doc create task`).
- **Wrong server** — `bp` talks to whatever the `env` block (or
  `~/.config/barkpark/`) points at; edit `BARKPARK_API_URL` or re-run
  `bp setup` to switch.
