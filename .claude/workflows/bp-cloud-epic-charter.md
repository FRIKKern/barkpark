# Epic charter slot — RETIRED as a slot; this file is now an index

**Do not write an epic charter into this file.** It is not a rotating slot any
more. Every epic keeps its own charter at its own stable path, and a wave that
appends here overwrites another epic's memory.

## Why this file still exists

`.claude/workflows/bp-epic-cycle.workflow.js` resolves `CHARTER_PATH` as
`A.charter_path || '.claude/workflows/bp-cloud-epic-charter.md'` — this path is
still the engine's fallback default, so deleting the file would make any wave
launched without an explicit `charter_path` read a file that is not there.
Retiring the default is a behaviour change for every future wave and belongs in
its own PR, not in a charter migration.

## What to do instead

Pass `charter_path` explicitly when launching a wave. The charter for an epic
lives at `.claude/workflows/<epic>-charter.md`, named for the epic task with any
trailing `-audit` dropped — e.g. epic task `api-controller-plug-correctness-audit`
→ `.claude/workflows/api-controller-plug-correctness-charter.md`. Older epics use
a `bp-` prefix (`bp-deploy-reliability-charter.md`); both forms are live, and
`ls .claude/workflows/*charter*.md` is the index.

## The rule this file exists to state

**One charter per epic, one continuous decision sequence per charter.** Decision
numbers run monotonically across every wave of an epic and are never restarted —
`bp-deploy-reliability-charter.md` runs D1–D604 across 90 waves. A wave that
restarts at D1 because it found an empty slot has created a collision, not a
fresh charter.

## Where this file's last occupant went

The clock-semantics charter that sat here (#12655, epic
`api-controller-plug-correctness-audit`) was folded into
`.claude/workflows/api-controller-plug-correctness-charter.md`, its decisions
renumbered D1–D35 → D23–D57 to continue that epic's single sequence.
