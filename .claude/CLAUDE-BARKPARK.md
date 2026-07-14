# Barkpark tasks (bp CLI)

All task tracking uses Barkpark — never markdown TODO lists, never a TODO tool.
The `bp` CLI talks to the configured server (`~/.config/barkpark/`).

- `bp task ready` — list available work
- `bp task next <worker>` — atomically claim the next ready task; claim FIRST — the claim returns the brief and an epoch
- `bp task get <id>` — task detail (carries children + child_count)
- `bp task close <id> <worker> <epoch>` — complete; epoch comes from your claim. If the claim lapsed, re-claim the same task for a fresh epoch, then close.
- `bp task create ...` — file new work (older binaries lack this verb; fall back to `bp doc create task`)
- `bp task prime <worker>` — one-call rehydration: your in-progress claims, ready head, recent events
- `bp task stamp <id> <worker> <epoch> --criterion N --met --evidence "…"` — record evidence on ONE criterion mid-claim. N is ZERO-BASED: the FIRST criterion is `--criterion 0`, the second is `--criterion 1` (do NOT pass a 1-based number — that silently stamps the wrong row). `--miss --note "…"` logs an honest attempt without flipping the lock; add `--criterion-text "<exact wording>"` to reject an off-by-one index instead of flipping a neighbour
- `bp task pulse <id> <worker> --now "…"` — write the now-line and renew the lease in one write (no epoch arg — it bumps the claim epoch)
- `bp capabilities -o json` — the whole API manifest when unsure

Conventions:
- Worker id: `claude-<your-name-or-branch>` — pick one and keep it for claim/close symmetry.
- `lifecycle_status` is the done-signal (`open` → `done`), not the claim record.
- Closing can mark acceptance criteria in the same atomic write:
  `--set 'criteria:=[{"index":0,"met":true,"evidence":"..."}]'`
- Nest large work with `parent_id` (a slug) for a Goal → sub-task tree; keep it flat otherwise.
- If a close 409s with `doc_changed_since_claim`, the brief changed under you — re-read the task, then close again.

MCP-native surface? The same verbs are first-class MCP tools via `bp mcp serve` — see `docs/setup/CLAUDE-CODE.md`.
