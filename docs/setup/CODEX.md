<!-- doc-tier: human | canonical-for: codex-onramp | budget: 1600tok -->
# Barkpark in Codex (CLI + Desktop)

Give your Codex agent a real task board: lifecycle, priorities, and an atomic
claim/close contract built for concurrent workers. Codex CLI and Codex Desktop
share one config file — `~/.codex/config.toml` — so one setup covers both.
Two minutes, three steps.

## 1. Install the `bp` CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

The installer drops `bp` in `/usr/local/bin`, falling back to `~/.local/bin`
when that isn't writable. If `bp: command not found`, the fallback directory
isn't on your `PATH` — add it (`export PATH="$HOME/.local/bin:$PATH"`) and
restart Codex so the child shell inherits it.

## 2. Authenticate

Point `bp` at a Barkpark and get a token — local admin token for a machine you
run, or the Barkpark Cloud auth-tunnel login for a hosted instance. Both
journeys, with the exact commands, live in `docs/setup/AGENT-ONRAMPS.md`.
Verify you're connected:

```bash
bp task ready     # empty list = connected, no open work
```

## 3. Register the MCP server

`bp mcp serve` runs a stdio MCP server that turns the CLI's capability manifest
into a tool catalog Codex calls directly — claim, read the brief, close with
epoch-CAS, never touching a shell. Register it once; it works in the CLI and the
Desktop app (same config file).

### The one-liner (CLI)

```bash
codex mcp add barkpark --env BARKPARK_API_URL=https://guerrilla.barkpark.cloud -- bp mcp serve
```

The `--` separates Codex's own flags from the command Codex will run. This
writes the core of the stanza below (`command`/`args`/`env`) into
`~/.codex/config.toml`; add `env_vars` and the timeouts by hand.

### Or hand-edit `~/.codex/config.toml`

```toml
[mcp_servers.barkpark]
command = "bp"
args = ["mcp", "serve"]
env = { BARKPARK_API_URL = "https://guerrilla.barkpark.cloud" }
env_vars = ["BARKPARK_API_TOKEN"]
startup_timeout_sec = 15
tool_timeout_sec = 120
```

Two keys carry the environment, and the difference is the whole security story:

- **`env`** sets static values written into the server's process. Put only
  **non-secret** config here — the API URL. This file is often committed or
  synced, so nothing secret goes in it.
- **`env_vars`** is a whitelist of variable **names** Codex forwards from your
  parent shell into the server. `BARKPARK_API_TOKEN` travels this way: set it in
  your profile (`export BARKPARK_API_TOKEN=…`) and the secret reaches `bp`
  without ever landing in a config file.

> **Never write `${BARKPARK_API_TOKEN}` inside a TOML value.** Codex does not
> document value-level variable expansion in `config.toml`, and an
> unexpanded `${VAR}` ships as that literal string — `bp` authenticates with
> garbage and every call 401s. Secrets travel through `env_vars`, never
> through `env` interpolation.

`startup_timeout_sec` (default 10) and `tool_timeout_sec` (default 60) are
raised here so a cold `bp` binary and a slow first manifest fetch don't trip the
launcher. Verify the server registered:

```bash
codex mcp list       # barkpark should appear
```

In the Codex TUI, `/mcp` lists the same servers and their tools.

### Per-project override

A repo-local `.codex/config.toml` can override the global one for that project —
handy for pinning a project at a different Barkpark. This override is honored by
the **Codex CLI in trusted projects**; keep team-wide MCP setup in the global
`~/.codex/config.toml` and use the per-project file only where you've verified it
takes effect. Never commit a token into either file — `env_vars` still carries
the secret.

## 4. Teach the agent (AGENTS.md)

Codex reads an `AGENTS.md` at the repo root as project instructions (up to
`project_doc_max_bytes`, default 32768). Drop this block in — it's ~1 KB, far
under the cap — so the agent knows the claim-first contract before it touches the
board. Don't hand-copy it: **`bp onramp agents-md` emits exactly this block**,
wrapped in `<!-- barkpark:onramp:begin -->` / `<!-- barkpark:onramp:end -->`
markers so a re-run updates only its own block and never your surrounding
`AGENTS.md` content:

```markdown
<!-- barkpark:onramp:begin -->
## Task tracking — Barkpark (bp)

All task tracking uses Barkpark — never markdown TODO lists, never a TODO tool.
The `bp` CLI talks to the configured server (`~/.config/barkpark/`).

- `bp task ready` — list available work
- `bp task next <worker>` — atomically claim the next ready task; claim FIRST — the claim returns the brief and an epoch
- `bp task get <id>` — task detail (carries children + child_count)
- `bp task close <id> <worker> <epoch>` — complete; epoch comes from your claim. If the claim lapsed, re-claim the same task for a fresh epoch, then close.
- `bp task create ...` — file new work (older binaries lack this verb; fall back to `bp doc create task`)
- `bp task prime <worker>` — one-call rehydration: your in-progress claims, ready head, recent events
- `bp capabilities -o json` — the whole API manifest when unsure

Conventions:
- Worker id: `<tool>-<your-name-or-branch>` — pick one and keep it for claim/close symmetry.
- `lifecycle_status` is the done-signal (`open` → `done`), not the claim record.
- Closing can mark acceptance criteria in the same atomic write:
  `--set 'criteria:=[{"index":0,"met":true,"evidence":"..."}]'`
- Nest large work with `parent_id` (a slug) for a Goal → sub-task tree; keep it flat otherwise.
- If a close 409s with `doc_changed_since_claim`, the brief changed under you — re-read the task, then close again.

MCP-native surface? The same verbs are first-class MCP tools via `bp mcp serve` — see `docs/setup/AGENT-ONRAMPS.md`.
<!-- barkpark:onramp:end -->
```

This is the ONE canonical teach text — the same body `.cursor/rules/barkpark-tasks.mdc`
and `.claude/CLAUDE-BARKPARK.md` carry in each tool's native framing. See
`docs/setup/AGENTS-MD.md` for the emitter and the merge semantics.

## The tools

Five curated task tools ship by default (`--tools tasks`), each carrying the
claim-first contract in its own description: `task_ready`, `task_next` (claim +
epoch), `task_show`, `task_close` (epoch-CAS + criteria), `task_create`.

`--tools all` (`args = ["mcp", "serve", "--tools", "all"]`) exposes **every**
manifest verb as a tool (`bp_<noun>_<verb>`), auto-derived from the live
capabilities — a new plugin's verbs appear with zero config change. That's ~107
tools; only reach for it if you know the handful you need. Keep the default
`tasks` otherwise.

## Troubleshooting

- **`bp: command not found` in Codex's terminal** — `~/.local/bin` isn't on the
  `PATH` Codex inherits. Add it and restart Codex (step 1).
- **Every tool call 401s** — you interpolated the token into `env`. Move it to
  `env_vars` and `export BARKPARK_API_TOKEN=…` in your shell (step 3).
- **Server fails at startup with `manifest has no task.<verb> verb`** — that
  Barkpark has the Tasks plugin disabled. `bp mcp serve` fails fast instead of
  coming up with zero tools; point the stanza at a Barkpark with Tasks enabled.
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback in the AGENTS.md block (`bp doc create task`).
- **Wrong server** — `bp` talks to whatever `~/.config/barkpark/` points at;
  re-run `bp setup` to switch, or override `BARKPARK_API_URL` in the stanza's
  `env`.
