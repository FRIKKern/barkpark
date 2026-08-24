# Barkpark tasks (bp CLI)

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
- Worker id: `claude-<your-name-or-branch>` — pick one and keep it for claim/close symmetry.
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

MCP-native surface? The same verbs are first-class MCP tools via `bp mcp serve` — see `docs/setup/CLAUDE-CODE.md`.
