<!-- doc-tier: human | canonical-for: cursor-integration | budget: 1600tok -->
# Barkpark in Cursor

Give your Cursor agent a real task board: lifecycle, priorities, and an atomic
claim/close contract built for concurrent workers. Two minutes, three steps.

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
bp task create "Fix the flaky search test" --publish \
  --set 'priority:=1' \
  --set 'acceptance_criteria:=[{"criterion":"test green 10x in a row","met":false,"evidence":""}]'
```

Open Cursor, ask the agent to pick up the next ready task, and watch the board.

## MCP (optional, coming)

`bp mcp serve` — a stdio MCP server exposing tasks as first-class MCP tools for
Cursor's non-terminal surfaces — is in flight. Until it lands, the rules file
above is the complete integration; it needs nothing but the `bp` binary.

## Troubleshooting

- **`bp: command not found` in Cursor's terminal** — the installer puts `bp` in
  `~/.local/bin`; make sure that's on the `PATH` Cursor inherits (restart Cursor
  after installing).
- **`task create` unknown verb** — old binary. Re-run the installer, or use the
  fallback documented in the rule (`bp doc create task`).
- **Wrong server** — `bp` talks to whatever `~/.config/barkpark/` points at;
  re-run `bp setup` to switch.
