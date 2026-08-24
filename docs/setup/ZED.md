<!-- doc-tier: human | canonical-for: zed-onramp | budget: 1600tok -->
# Barkpark in Zed

Give Zed's Agent Panel a real task board: lifecycle, priorities, and an atomic
claim/close contract built for concurrent workers, wired in as first-class MCP
tools ("context servers"). Two minutes, three steps.

**Register the movement** — every unit of work runs under a claimed `bp` task: claim before you work, stamp evidence as you prove it, close on the claim epoch. The full doctrine, and the three ways a registration silently does not happen, is in [Agent Onramps](AGENT-ONRAMPS.md).

See also: [Agent Onramps](AGENT-ONRAMPS.md) — the shared AUTH + CREATE journeys
and the same onramp for every other agent surface.

## 1. Install the `bp` CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

If `bp: command not found` afterward, the installer's fallback dir isn't on your
`PATH` — add it (`export PATH="$HOME/.local/bin:$PATH"`) and restart Zed so its
child shell inherits it.

## 2. Authenticate — and why Zed needs it done FIRST

Point `bp` at a Barkpark and get a token — a local admin token for a machine you
run, or the Barkpark Cloud auth-tunnel login for a hosted instance. Both journeys,
with the exact commands, live in `docs/setup/AGENT-ONRAMPS.md`. Verify:

```bash
bp task ready     # empty list = connected, no open work
```

**This step is not optional for Zed.** Unlike Cursor or VS Code, Zed does **not**
expand `${env:VAR}` / `${VAR}` placeholders inside `settings.json` (tracked
upstream: zed#26043, zed#28632, zed#18630, zed#53780). So the barkpark context
server below carries an **empty `env {}`** — it passes no URL and no token. Instead
`bp` reads its server + token from its OWN saved config
(`~/.config/barkpark/config.json`, written by `bp setup`). Configure `bp` first and
the Zed stanza just works; skip it and the server starts with no credential.

**Never paste a literal token into `settings.json`.** It is a plaintext editor
config, often synced or committed — the credential belongs in `~/.config/barkpark/`
(mode `0600`), not here.

## 3. Register the context server

`bp mcp serve` runs a stdio MCP server that turns the CLI's capability manifest
into a tool catalog Zed's Agent Panel calls directly — claim, read the brief, close
with epoch-CAS, never touching a shell.

Zed reads MCP servers as **context servers** from your GLOBAL
`~/.config/zed/settings.json` (open it with `zed: open settings`). The entry is
**flat** — `command`, `args`, `env` directly, with **no `source` key** (that shape
is Zed-internal only). If the file already holds other context servers or settings,
**merge** the `barkpark` entry into a top-level `context_servers` object — don't
overwrite the whole file:

```json
{
  "context_servers": {
    "barkpark": {
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {}
    }
  }
}
```

`env` is intentionally empty (see step 2): `bp` resolves the server and token from
`~/.config/barkpark/`, so nothing sensitive lands in `settings.json`.

`bp onramp zed` prints this exact stanza and its destination path.
`bp onramp zed --write` merges just the `barkpark` entry into `settings.json` for
you (idempotent; foreign context servers and unrelated settings are preserved).

Verify by reloading Zed (or run `zed: reload`); `barkpark` appears in the Agent
Panel, and its task tools show up in the agent's tool list.

### Retargeting

Because the `env` is empty, this stanza aims wherever `bp` is pointed —
`bp setup --target connect --server <url> --token <token>` (or the
`BARKPARK_API_URL` / `BARKPARK_API_TOKEN` shell vars the `bp` process inherits)
decide the instance, not `settings.json`. A server whose Tasks plugin is disabled
fails fast at startup with a clear `manifest has no task.<verb> verb` error on
stderr; point `bp` at a Barkpark with Tasks enabled.

## Teach Zed the task contract

Zed reads repo-root project rules from `.rules` (and the emerging `AGENTS.md`
convention — `bp onramp agents-md` emits that block). Drop the claim-first contract
there so the agent knows to claim before working, stamp evidence into acceptance
criteria, and close with the claim epoch — the same contract every other onramp
teaches.

## The tools

Eight curated task tools ship by default (`--tools tasks`), each carrying the
claim-first contract in its own description: `task_ready`, `task_next` (claim +
epoch), `task_show`, `task_close` (epoch-CAS + criteria), `task_create`,
`task_prime` (one-call rehydration for a resuming agent), `task_stamp`
(criterion evidence mid-claim), `task_pulse` (now-line + lease renewal).

`--tools all` (`"args": ["mcp", "serve", "--tools", "all"]`) exposes **every**
manifest verb as a tool (`bp_<noun>_<verb>`), auto-derived from the live
capabilities — a new plugin's verbs appear with zero config change. That's ~107
tools; keep the default `tasks` unless you know the handful you need.

## Troubleshooting

- **`bp: command not found` in Zed's server log** — `~/.local/bin` isn't on the
  `PATH` Zed inherits. Add it and restart Zed (step 1).
- **Server starts but every call fails auth** — `bp` has no saved credential.
  Zed passes none (empty `env {}`), so run `bp setup` / `bp login` first (step 2)
  and confirm `bp task ready` works from your shell.
- **`bp onramp zed --write` errors with a JSON parse error** — your
  `settings.json` contains `//` comments (JSONC), which the safe JSON merge can't
  parse. Paste the stanza by hand, or strip comments from the file first.
- **Server fails at startup with `manifest has no task.<verb> verb`** — that
  Barkpark has the Tasks plugin disabled. Point `bp` at one with Tasks on.
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback (`bp doc create task`).
