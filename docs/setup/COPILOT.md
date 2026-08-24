<!-- doc-tier: human | canonical-for: copilot-onramp | budget: 1600tok -->
# Barkpark in VS Code (GitHub Copilot)

Give your Copilot agent a real task board: lifecycle, priorities, and an atomic
claim/close contract built for concurrent workers, wired in as first-class MCP
tools. Two minutes, three steps.

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

If `bp: command not found` afterward, the installer's fallback dir isn't on your
`PATH` — add it (`export PATH="$HOME/.local/bin:$PATH"`) and restart VS Code so
Copilot's child shell inherits it.

## 2. Authenticate

Point `bp` at a Barkpark and get a token — a local admin token for a machine you
run, or the Barkpark Cloud auth-tunnel login for a hosted instance. Both
journeys, with the exact commands, live in `docs/setup/AGENT-ONRAMPS.md`. Verify:

```bash
bp task ready     # empty list = connected, no open work
```

## 3. Register the MCP server

`bp mcp serve` runs a stdio MCP server that turns the CLI's capability manifest
into a tool catalog Copilot calls directly — claim, read the brief, close with
epoch-CAS, never touching a shell.

VS Code reads workspace MCP servers from `.vscode/mcp.json` (checked into the
repo). Its top-level key is **`servers`** — **not** `mcpServers`, the shape every
other agent uses (VS Code renamed it during the MCP preview). If that file
already holds other servers, **merge** the `barkpark` entry into `servers` —
don't overwrite the whole file:

```json
{
  "servers": {
    "barkpark": {
      "type": "stdio",
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

`"type": "stdio"` marks a locally-run server; `${env:BARKPARK_API_TOKEN}` reads
the token from your shell environment, so the secret never lands in the committed
file — set it in your profile (`export BARKPARK_API_TOKEN=…`). This is VS Code's
dialect; it happens to match Cursor's `${env:VAR}` form but is its own — keep the
`env:` prefix.

`bp onramp copilot` prints this exact stanza and its destination path. Verify by
running **MCP: List Servers** from the Command Palette (`Cmd/Ctrl+Shift+P`);
`barkpark` appears, and its task tools show up in Copilot **agent mode**'s tool
picker.

**Prompt for the token instead of a shell var?** VS Code's `inputs` array
collects secrets interactively and stores them in VS Code's secret storage.
Reference the value with `${input:<id>}`:

```json
{
  "inputs": [
    { "type": "promptString", "id": "bp-token", "description": "Barkpark API token", "password": true }
  ],
  "servers": {
    "barkpark": {
      "type": "stdio",
      "command": "bp",
      "args": ["mcp", "serve"],
      "env": {
        "BARKPARK_API_URL": "https://guerrilla.barkpark.cloud",
        "BARKPARK_API_TOKEN": "${input:bp-token}"
      }
    }
  }
}
```

**Copilot coding agent (cloud, not local):** the cloud agent doesn't read your
local shell. Configure its MCP servers in the repository's Copilot settings and
supply the token as a `COPILOT_MCP_*` repository secret (repo → Settings →
Environments / Copilot) rather than through this file.

### Retargeting

The `env` block is the whole instance override. `bp`'s environment layer sits
**above** the `~/.config/barkpark/` config file, so `BARKPARK_API_URL` +
`BARKPARK_API_TOKEN` in the stanza aim this server at any Barkpark — a hosted
instance, a teammate's, or `http://localhost:4000` — no matter what `bp setup`
saved. A server whose Tasks plugin is disabled fails fast at startup with a clear
`manifest has no task.<verb> verb` error on stderr; point the stanza at a
Barkpark with Tasks enabled.

## Teach Copilot the task contract

VS Code reads repo-root project instructions from `.github/copilot-instructions.md`
(and the emerging `AGENTS.md` convention). Drop the claim-first contract there so
the agent knows to claim before working, stamp evidence into acceptance criteria,
and close with the claim epoch — the same contract every other onramp teaches.

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

- **`bp: command not found` in Copilot's terminal** — `~/.local/bin` isn't on the
  `PATH` VS Code inherits. Add it and restart VS Code (step 1).
- **Server not listed** — run **MCP: List Servers** from the Command Palette; a
  syntax slip in `.vscode/mcp.json` stops it from loading, so validate the JSON.
  Confirm the top-level key is `servers`, not `mcpServers`.
- **Server fails at startup with `manifest has no task.<verb> verb`** — that
  Barkpark has the Tasks plugin disabled. Point the stanza at one with Tasks on.
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback (`bp doc create task`).
