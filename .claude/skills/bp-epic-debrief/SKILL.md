---
name: bp-epic-debrief
description: Compose a full Barkpark epic into ONE premium, human-first debrief Paper — narrative arc, per-wave journey highlights, cross-wave telemetry trends, and a process retro with teeth. Invoke when the user says "debrief epic <id>", "epic debrief", "write the epic story", or names an epic task to debrief. Runs days or weeks after the waves; reads only durable stores (Papers, ledger, charter, git). Part of the epic-memory design (.claude/workflows/bp-epic-cycle-epic-memory-design.md).
---

# Epic Debrief — an author with taste, not a report generator

You are composing the story of a whole epic for a human who wants fast, premium insight. One Fable-grade author pass; reviewer discipline folded in (re-read the rendered Paper before publishing, fix what reads badly).

## Inputs

`<epic-task-id>` (required — ask if missing). Everything else is derived:

1. `bp task show <epic-task-id>` — children (slices, backlog), `wave_status`, `wave_paper` pointers.
2. The epic charter named by the task or its Papers (`.claude/workflows/<epic>-charter.md`): Vision, Decisions, Roadmap, Wave log.
3. Every wave Paper: follow `wave_paper` fields + `bp search query "<epic> wave"` — these carry journey cards, decisions, proofs, facts tables, telemetry + retro sections.
4. `git log --oneline` + merged PRs touching the epic's surfaces (task ids in PR bodies: `Task: <id>`).

DURABLE STORES ONLY — session files from wave runs are gone; never claim data that is not in a Paper, the ledger, the charter, or git (the design's forcing constraint). If a wave predates telemetry, SAY SO in the Paper — never backfill numbers (honesty rule D9).

## Compose (block crib: helpers/blocks.md — exact JSON shapes)

One Paper, slug `<epic>-debrief-<YYYY-MM-DD>`, style=article MANDATORY, published via one atomic `/v1/data/mutate` batch (create + publish), registered tags only (`bp tag browse`).

Structure the story, component per job:
- eyebrow · heading · byline · ingress — the epic in one breath.
- stat-grid — headline numbers: waves, slices shipped/deferred, PRs merged, total tokens, wall-clock span, interrupts.
- steps or pipeline — the epic's arc wave by wave: ambition → obstacles → turning points → what stands.
- Per wave: heading + a journey-highlight cards block (the 2-4 BEST moments across that wave's agents — surprises and refuted premises beat routine wins) + callouts for the decisions that shaped what followed.
- table — shipped vs deferred vs stalled, with task ids and PR links.
- chart — cross-wave trends from the telemetry sections (tokens per phase per wave; did Decide get cheaper as the charter matured?). Only measured data; state grain.
- THE RETRO WITH TEETH: table of per-phase verdicts across waves, then cards with your top-3 process changes — each argued from telemetry rows or journey moments. Offer to file each as a published bp backlog task under the epic (ask first).
- pullquote for the epic's one-line lesson; expandable for source anchors (papers, tasks, PRs read).

## Seal

1. Read the published Paper back top-to-bottom; fix anything that reads as a dump.
2. Stamp the epic task: flat `epic_debrief=<paper-id>` via patch + re-publish.
3. Reply with the Paper URL and a 3-line summary.
