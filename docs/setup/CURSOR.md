<!-- doc-tier: human | canonical-for: cursor-integration | budget: 1600tok -->
# Barkpark in Cursor

Give your Cursor agent a real task board: lifecycle, priorities, and an atomic
claim/close contract built for concurrent workers. Two minutes, three steps.

**Register the movement** — every unit of work runs under a claimed `bp` task: claim before you work, stamp evidence as you prove it, close on the claim epoch. The full doctrine, and the three ways a registration silently does not happen, is in [Agent Onramps](AGENT-ONRAMPS.md).

See also: [Agent Onramps](AGENT-ONRAMPS.md) — the shared AUTH + CREATE journeys and the same onramp for every other agent surface (Cursor Cloud, Claude Code, Codex, ChatGPT, Claude.ai).

## 1. Install the `bp` CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

## 2. Connect to a Barkpark

```bash
bp setup          # local · deploy · connect — pick one, it does the rest
```

`connect` points `bp` at an existing server (yours or a hosted one) and stores
the config in `~/.config/barkpark/`. No Barkpark yet? `local` runs one on your
machine; `deploy` installs on your own server over SSH. Verify:

```bash
bp task ready     # empty list = connected, no open work
```

## 3. Teach Cursor

Copy the ready-made rule into your repo — Cursor loads it automatically:

```bash
mkdir -p .cursor/rules
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/.cursor/rules/barkpark-tasks.mdc \
  -o .cursor/rules/barkpark-tasks.mdc
```

The rule teaches the agent the whole contract: claim before working
(`bp task next <worker>`), stamp evidence into acceptance criteria, close with
the claim epoch, and recover from `doc_changed_since_claim`. From then on,
"what should I work on?" in Cursor means `bp task ready`, and finished work is
closed on the board — no markdown TODO lists.

That's it. The agent discovers everything else itself: `bp capabilities -o json`
returns the entire API — every noun, verb, and route — in one call.

## Filing work for the agent

```bash
# `tags` are weighted labels [{tag, strength 1–100, rationale}], mandatory on
# publish; each `tag` must be a registered tag doc (`bp doc ls tag`) or the
# publish 422s `unknown_tag`. Strengths are distinct; the max is the main tag.
bp task create "Fix the flaky search test" --publish \
  --set 'priority:=1' \
  --set 'tags:=[{"tag":"search","strength":80,"rationale":"the flaky test exercises the search path"},{"tag":"testing","strength":50,"rationale":"stabilising a flaky test is test-reliability work"}]' \
  --set 'acceptance_criteria:=[{"criterion":"test green 10x in a row","met":false,"evidence":""}]'
```

Open Cursor, ask the agent to pick up the next ready task, and watch the board.

## MCP (Model Context Protocol)

Section 3 is path A — the agent shells out to `bp` from Cursor's terminal. Path B
gives MCP-native surfaces the same board as **first-class tools**: `bp mcp serve`
runs a stdio MCP server that turns the CLI's capability manifest into a tool
catalog the Agent calls directly — claim, read the brief, close with epoch-CAS,
never touching a shell.

### Register it

Add one server to Cursor's MCP config. Put it in `~/.cursor/mcp.json` (**global** —
every project) or `.cursor/mcp.json` in the repo root (**per-project**); the shape
is identical and project config wins where both name the same server:

```json
{
  "mcpServers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${env:BARKPARK_API_TOKEN}"
      }
    }
  }
}
```

Restart Cursor (or reload MCP servers in Settings) and the task tools show up in
the Agent's tool list. `${env:BARKPARK_API_TOKEN}` reads the token from your shell
environment, so the secret never lands in a committed file — set it in your
profile (`export BARKPARK_API_TOKEN=…`).

### Retargeting without `bp setup`

The `env` block is the whole instance override. `bp`'s environment layer sits
**above** the `~/.config/barkpark/` config file, so `BARKPARK_API_URL` +
`BARKPARK_API_TOKEN` in the stanza aim this server at any Barkpark — a hosted
instance, a teammate's, or `http://localhost:4000` — no matter what `bp setup`
saved. A server whose Tasks plugin is disabled fails fast at startup (under the
default `--tools tasks`) with a clear `manifest has no task.<verb> verb` error
on stderr — better than coming up healthy-looking with zero tools. Point the
stanza at a Barkpark with Tasks enabled.

### The tools

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

### Resources: published papers

The server also exposes every **published paper** as a read-only MCP resource
(`barkpark://papers/<id>`, raw JSON) — browse them in the client's resource
picker and pull one into context. Independent of `--tools`; if the API is
unreachable at startup the list degrades gracefully (papers still read by id).

### `--tools all` (expert only)

`"args": ["mcp", "serve", "--tools", "all"]` exposes **every** manifest verb as a
tool (`bp_<noun>_<verb>`), auto-derived from the live capabilities — a new plugin's
verbs appear with zero code changes. Caveat: **Cursor hard-caps 40 MCP tools across
all enabled servers and silently drops the excess.** The full Barkpark manifest is
~107 commands, so `all` blows past the cap. Keep the default `tasks` unless you
know exactly which handful you need. On a Barkpark with the Tasks plugin
disabled, `--tools all` still starts (bridge-only, after a one-line stderr
warning) whereas the default `--tools tasks` refuses — there are no task verbs to
back the curated tools.

### Validation

`bp mcp serve` is proven against a live server (real JSON-RPC transcript, not a
fixture) in [`../ops/mcp-serve-validation.md`](../ops/mcp-serve-validation.md).

## Troubleshooting

- **`bp: command not found` in Cursor's terminal** — the installer puts `bp` in
  `~/.local/bin`; make sure that's on the `PATH` Cursor inherits (restart Cursor
  after installing).
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback documented in the rule (`bp doc create task`).
- **Wrong server** — `bp` talks to whatever `~/.config/barkpark/` points at;
  re-run `bp setup` to switch.
