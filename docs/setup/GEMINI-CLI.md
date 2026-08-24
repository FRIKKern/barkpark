<!-- doc-tier: human | canonical-for: gemini-cli-onramp | budget: 1600tok -->
# Barkpark in Gemini CLI

Give your Gemini CLI agent a real task board: lifecycle, priorities, and an
atomic claim/close contract built for concurrent workers, wired in as
first-class MCP tools. Two minutes, three steps.

**Register the movement** — every unit of work runs under a claimed `bp` task: claim before you work, stamp evidence as you prove it, close on the claim epoch. The full doctrine, and the three ways a registration silently does not happen, is in [Agent Onramps](AGENT-ONRAMPS.md).

See also: [Agent Onramps](AGENT-ONRAMPS.md) — the shared AUTH + CREATE journeys
and the same onramp for every other agent surface.

## 1. Install the `bp` CLI

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
```

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.ps1 | iex
```

If `bp: command not found` afterward, add the installer's fallback dir to your
`PATH` (`export PATH="$HOME/.local/bin:$PATH"`) and restart the Gemini CLI.

## 2. Authenticate

Point `bp` at a Barkpark and get a token — a local admin token for a machine you
run, or the Barkpark Cloud auth-tunnel login for a hosted instance. Both
journeys, with the exact commands, live in [Agent Onramps](AGENT-ONRAMPS.md). Verify:

```bash
bp task ready     # empty list = connected, no open work
```

## 3. Register the MCP server

`bp mcp serve` runs a stdio MCP server that turns the CLI's capability manifest
into a tool catalog Gemini CLI calls directly — claim, read the brief, close with
epoch-CAS, never touching a shell.

Gemini CLI reads MCP servers from `settings.json`. The project-local
`.gemini/settings.json` (checked into the repo) is the default target; the
global `~/.gemini/settings.json` covers every project. Either file holds your
**whole** CLI config, so **merge** the `barkpark` entry into any existing
`mcpServers` object — don't overwrite the file:

```json
{
  "mcpServers": {
    "barkpark": {
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

Gemini CLI expands `$VAR` and `${VAR}` inside `settings.json` values, so
`${BARKPARK_API_TOKEN}` reads the token from your shell environment and the
secret never lands in the committed file — set it in your profile
(`export BARKPARK_API_TOKEN=…`). This is the Gemini CLI dialect; it is **not**
the Cursor-only `${env:VAR}` form, which would ship as a literal string here.

`bp onramp gemini-cli` prints this exact stanza and its destination path. Verify:

```bash
gemini mcp list       # barkpark should appear (or /mcp inside the CLI)
```

### Retargeting

The `env` block is the whole instance override. `bp`'s environment layer sits
**above** the `~/.config/barkpark/` config file, so `BARKPARK_API_URL` +
`BARKPARK_API_TOKEN` in the stanza aim this server at any Barkpark — a hosted
instance, a teammate's, or `http://localhost:4000` — no matter what `bp setup`
saved. A server whose Tasks plugin is disabled fails fast at startup with a clear
`manifest has no task.<verb> verb` error on stderr; point the stanza at a
Barkpark with Tasks enabled.

## Teach the agent the task contract (GEMINI.md)

Gemini CLI reads a `GEMINI.md` at the repo root as project instructions (and the
emerging `AGENTS.md` convention). Drop the claim-first contract there so the
agent knows to claim before working, stamp evidence into acceptance criteria,
and close with the claim epoch — the same contract every other onramp teaches.

## The tools

Eight curated task tools ship by default (`--tools tasks`), each carrying the
claim-first contract in its own description: `task_ready`, `task_next` (claim +
epoch), `task_show`, `task_close` (epoch-CAS + criteria), `task_create`,
`task_prime` (one-call rehydration for a resuming agent), `task_stamp`
(criterion evidence mid-claim), `task_pulse` (now-line + lease renewal).

`--tools all` (`"args": ["mcp", "serve", "--tools", "all"]`) exposes **every**
manifest verb as a tool (`bp_<noun>_<verb>`), auto-derived from the live
capabilities. That's ~107 tools; keep the default `tasks` unless you know the
handful you need.

## Troubleshooting

- **`bp: command not found`** — `~/.local/bin` isn't on the `PATH` the Gemini CLI
  inherits. Add it and restart (step 1).
- **Server not listed** — a syntax slip in `settings.json` stops the whole file
  from loading; validate the JSON, then re-run `gemini mcp list`.
- **Server fails at startup with `manifest has no task.<verb> verb`** — that
  Barkpark has the Tasks plugin disabled. Point the stanza at one with Tasks on.
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback (`bp doc create task`).
