# Epic-cycle phase contract

Use this checklist to keep phase boundaries observable and resumable.

| Phase | Durable input | Durable output | Exit gate |
| --- | --- | --- | --- |
| Prime | user wish, epic id, charter | current-state brief | target and stop condition explicit |
| Strategize | brief | published wave Paper; epic heartbeat | Paper read back |
| Survey | survey assignments | coverage-accounted reports | all assignments accounted for |
| Digest | survey reports | Paper digest and proof plan | decision-critical unknowns named |
| Verify | proof plan | commands, output excerpts, verdicts | claims proven/refuted/carried as risk |
| Decide | verified evidence | charter commit; published slice tasks; Paper wave plan | tasks read back and gates dry-run |
| Build | claimable slice tasks | committed, gated branches; criterion stamps | accepted slices green and truthful |
| Review | branches and ledger | reviewed branches; grade; charter log; Paper debrief | wave stop condition proven |

Every phase also updates the Paper's **Agent fleet** counts. The fleet gate is 24 completed typed child assignments: Survey 12, Verify 6, Build 3 at high effort, Review 3. The leader and retries do not count.

## Invariants

- Preserve the user's wish verbatim in the wave Paper.
- Barkpark tasks are the execution ledger; do not substitute markdown TODOs.
- The wave Paper is the phase narrative; fan-out workers never write it.
- The charter is long-lived decision memory; the Paper is one wave's story.
- Strategy and decisions use high effort. Survey and Verify use medium effort; Build and Review use high effort.
- The leader owns mutations, synthesis, integration, and completion claims.
- Negative findings and failed commands are evidence, not embarrassment.
- A passing test proves only the behavior it actually exercises.
- Builders claim before edits, pulse while active, and stamp evidence immediately.
- Merge-gated criteria remain open until the merge is authoritative.
- A published, claimed Barkpark task is a precondition to implementation, not retrospective bookkeeping.
- Every claim pulse invalidates cached epochs; reread before stamp or close.
- PR bodies are file-backed and contain one exact physical `Task: <id>` line.
- Typed subagents are used only when the surface can explicitly select their `agent_type`; fallback remains phase-separated and honest.

## Minimum wave Paper sections

1. User wish
2. Strategic direction
3. Survey plan
4. Survey digest and coverage gaps
5. Verification plan
6. Verification proofs
7. Decisions and rationale
8. Wave slices, task ids, order, file ownership, gates
9. Debrief, grade, risks, and next direction

## Task quality check

A slice is ready only when its published task has one parent epic, an outcome-shaped title, sufficient cold-start context, exact file ownership, checkable criteria, a runnable gate, real blockers, and a link to the wave Paper. Read it back from the server before dispatch.

Use `../scripts/validate_epic_cycle.py` to enforce the machine-checkable subset before dispatch and before PR creation. A root epic is valid for the Strategize preflight even when it has no parent or criteria, but Strategize always requires `--wish-file` to prove verbatim preservation. Canonical Papers require live CycleFleet comparison with explicit `--workspace` and `--project` scope. The narrowly named `--allow-pre-cyclefleet-paper-without-ledger` flag is accepted only when the Paper's immutable `_createdAt` is before the documented CycleFleet cutoff `2026-07-15T00:05:00Z`; the flag alone is never provenance. Review has two gates: `--phase review` checks its prerequisites, while `--phase review --require-debrief` proves its output after the debrief is published.
