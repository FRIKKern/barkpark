<!-- doc-tier: human | canonical-for: codex-onramp | budget: 2600tok -->
# Barkpark in Codex (CLI + Desktop)

Give your Codex agent a real task board: lifecycle, priorities, and an atomic
claim/close contract. Codex CLI and Codex Desktop share one config file —
`~/.codex/config.toml` — so one setup covers both.

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
when that isn't writable. If `bp: command not found`, add that fallback to your
`PATH` (`export PATH="$HOME/.local/bin:$PATH"`) and restart Codex.

## 2. Authenticate

Point `bp` at a Barkpark and get a token — local admin token for a machine you
run, or the Barkpark Cloud auth-tunnel login for a hosted instance. Both
journeys, with the exact commands, live in [Agent Onramps](AGENT-ONRAMPS.md).
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

<!-- grammar verified 2026-07-10 against openai/codex codex-rs/cli/src/mcp_cmd.rs: usage `codex mcp add [OPTIONS] <NAME> (--url <URL> | -- <COMMAND>...)`; --env takes KEY=VALUE (stdio only); the NAME precedes the `--` command -->
<!-- write shape verified 2026-07-11 against codex-cli 0.144.1 (live capture) + openai/codex@5c19155c: `codex mcp add` writes env as a NESTED [mcp_servers.barkpark.env] sub-table (alpha-sorted keys), NOT the inline env = {…} form -->

The `--` separates Codex's own flags from the command it will run. This writes
`command`/`args` into `~/.codex/config.toml`, with `env` as a **nested
`[mcp_servers.barkpark.env]` sub-table** rather than the inline `env = {…}` form
below (both are valid TOML). Add `env_vars` and the timeouts by hand, or run
`bp onramp codex --write --force` for the full canonical stanza.

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
raised so a cold `bp` binary and a slow first manifest fetch don't trip the
launcher. Verify the server registered:

```bash
codex mcp list       # barkpark should appear
```

In the Codex TUI, `/mcp` lists the same servers and their tools.

### Or let `bp` write it — `bp onramp codex --write`

`bp onramp codex --write` merges the stanza above into `~/.codex/config.toml`
for you — a textual span splice owning **only** the `[mcp_servers.barkpark]`
table and its sub-tables; every byte outside that span survives verbatim. It is
idempotent and honest per file (`created` / `updated` / `unchanged` /
`skipped`); `--force` replaces a differing span, including the sub-table shape
`codex mcp add` writes. Full merge semantics, exit codes and the `-o json`
shape: [Agent Onramps](AGENT-ONRAMPS.md).

```bash
bp onramp codex --write             # merge the [mcp_servers.barkpark] span
bp onramp codex --write --force     # replace a differing span (e.g. codex mcp add output)
```

### Per-project override

A repo-local `.codex/config.toml` can pin one project at a different Barkpark —
honored by the **Codex CLI in trusted projects**. Keep team-wide setup global and
use the per-project file only where you've verified it takes effect. Never commit
a token into either file — `env_vars` carries the secret.

## 4. Teach the agent (AGENTS.md)

Codex reads an `AGENTS.md` at the repo root as project instructions (up to
`project_doc_max_bytes`, default 32768). Drop this block in — well under the cap
— so the agent knows the claim-first contract before it touches the board. Don't
hand-copy it: **`bp onramp agents-md` emits exactly this block**, wrapped in
`<!-- barkpark:onramp:begin -->` / `<!-- barkpark:onramp:end -->` markers so a
re-run updates only its own block, never your surrounding content:

```markdown
<!-- barkpark:onramp:begin -->
## Task tracking — Barkpark (bp)

**Register the movement.** Every unit of work — build, research, plan, audit, spike — runs under a claimed task: if no row names it, create one and claim it FIRST, then work. Unregistered work is unrecoverable — a lost session is rebuilt only from the ledger, and "what has been going on lately" is answerable only from task events.

Three ways a registration you think you made never landed:
- A redirected or piped stdin makes `bp` REFUSE a mutating write (exit 2, `piped stdin is unused`) — in a heredoc-fed script every claim/create/stamp aborts while the reads around them succeed. Pass arguments, never a pipe.
- A write to a remote server without `--yes` aborts (exit 2, `prod write not confirmed`). It fires AFTER the stdin refusal, so fixing one can reveal the other.
- A printed receipt is not persistence. Read the row back and match a string you wrote.

All task tracking uses Barkpark — never markdown TODO lists, never a TODO tool.
The `bp` CLI talks to the configured server (`~/.config/barkpark/`).

- `bp task ready` — list available work
- `bp task next <worker>` — atomically claim the next ready task; claim FIRST — it returns the brief and an epoch
- `bp task get <id>` — task detail (carries children + child_count)
- `bp task close <id> <worker> <epoch>` — complete; epoch comes from your claim. Lapsed? re-claim for a fresh epoch, then close.
- `bp task create ...` — file new work (older binaries lack this verb; fall back to `bp doc create task`)
- `bp task prime <worker>` — one-call rehydration: your in-progress claims, ready head, recent events
- `bp task stamp <id> <worker> <epoch> --criterion N --criterion-text "<its wording>" --met --evidence "…"` — evidence on ONE criterion mid-claim. N is ZERO-BASED (first = 0); `--criterion-text` is REQUIRED for `--met` — an unguarded flip is REFUSED. `--miss --note "…"` = honest attempt, no flip.
- `bp task pulse <id> <worker> --now "…"` — now-line + lease renewal in one write (no epoch arg — it bumps the claim epoch)
- `bp capabilities -o json` — the whole API manifest when unsure

Conventions:
- Worker id: `<tool>-<your-name-or-branch>` — pick one and keep it for claim/close symmetry.
- `lifecycle_status` is the done-signal (`open` → `done`), not the claim record.
- Closing marks criteria in the same atomic write; a met:true entry MUST carry the criterion's exact wording:
  `--set 'criteria:=[{"index":0,"met":true,"evidence":"...","criterion":"<wording>"}]'`
- Nest large work with `parent_id` (a slug) for a Goal → sub-task tree; keep it flat otherwise.
- If a close 409s `doc_changed_since_claim`, re-read the changed brief, then close with `--set observed_rev=<current_rev>` (the rev the 409 names); a bare re-read then close just repeats the 409.

Papers (design docs, specs, reports) live in Barkpark too — never hand-roll an HTML file:
- `bp bulldocs publish <slug> --file payload.json` — the write door; the same slug MUST also appear as `"slug"` INSIDE the JSON, not just on the command line.
- The payload is `blocks` — the renderer's own block deck (chart, diagram, asciicast, diff, table, callout, …). `body_html` is a legacy last resort that renders flat.
- Inline leaves are VALUE-KEYED: every `items`/`cells` entry is an object carrying a `value` key, never a bare string — a bare string publishes clean and renders BLANK.
- `bp paper view <slug>` reads one back in the terminal. Authoring guide: `/papers/paper-authoring-excellence`.

MCP-native surface? The same verbs are first-class MCP tools via `bp mcp serve` — see `docs/setup/AGENT-ONRAMPS.md`.
<!-- barkpark:onramp:end -->
```

This is the ONE canonical teach text — the same body `.cursor/rules/barkpark-tasks.mdc`
and `.claude/CLAUDE-BARKPARK.md` carry in each tool's native framing. See
`docs/setup/AGENTS-MD.md` for the emitter and the merge semantics.

## 5. Author papers — the BPML working-copy door

The teach block above names the raw JSON door (`bp bulldocs publish`); for
anything an agent iterates on, teach the working-copy door instead — a local
`.bpml` file is the draft, the server is the truth:

```bash
bp paper new my-report                    # local scaffold: .barkpark/papers/my-report.bpml
$EDITOR .barkpark/papers/my-report.bpml   # edit the BPML working copy
bp paper push my-report                   # validate + publish (creates the paper if absent)
```

`bp paper new` runs locally — no server call — and emits a starter that already
passes the publish wall: a title heading, a real opening paragraph, a ≥20-char
description, weighted tags. Tags must be **registered** on the server (`bp doc
ls tag`); the scaffold never invents them — an unregistered tag is the classic
first-push 422. `bp paper pull <slug>` fetches an existing paper into the same
working copy. The grammar, the width law, and every publish-wall error with its
remedy: `/papers/paper-authoring-excellence`.

## The tools

Eight curated task tools ship by default (`--tools tasks`), each carrying the
claim-first contract in its own description: `task_ready`, `task_next` (claim +
epoch), `task_show`, `task_close` (epoch-CAS + criteria), `task_create`,
`task_prime` (one-call rehydration for a resuming agent), `task_stamp`
(criterion evidence mid-claim), `task_pulse` (now-line + lease renewal).

`--tools all` (`args = ["mcp", "serve", "--tools", "all"]`) exposes **every**
manifest verb as `bp_<noun>_<verb>`, auto-derived from live capabilities, so a
new plugin's verbs appear with zero config change — ~107 tools. Keep the default
`tasks` unless you know the handful you need.

## Troubleshooting

- **`bp: command not found`** — `~/.local/bin` isn't on the `PATH` Codex
  inherits. Add it and restart Codex (step 1).
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
