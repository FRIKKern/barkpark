<!-- doc-tier: agent | canonical-for: pr-body-criterion-rule | budget: 700tok -->
# 0005 — A criterion proved by a PR body is closed over, never flipped

**Status:** Accepted 2026-08-22
**Deciders:** Barkpark owner (ruling), lead (drafting)
**Related:** [../setup/TASK-SYSTEM.md](../setup/TASK-SYSTEM.md) (operative line) · `Criteria.merge_gated?/1`

## Context

Acceptance criteria of the shape *"the PR body states X"* are satisfiable only **before**
merge. Nobody edits a merged PR's body, so the moment the PR lands the criterion becomes
unpayable — and the row sits open forever at N-1/N, inflating its epic's open count.

The class was diagnosed **four times across four waves** and never resolved:
`dr-bl-w5` (wave 5) → `dr-w10-bl` (wave 10) → `dr-w14-bl` (wave 14) → `dr-w19-bl` (wave 19),
each blocked on its predecessor, every one at 0/N. The outermost is titled *"…and stop the
sweep being ordered a fourth time."* It became the fourth. Meanwhile the deploy-reliability
charter names the defect at five separate lines — always as a description, never as a rule.

**A diagnosed defect is not a written rule.** Counting diagnoses as progress is what let
this be re-filed four times.

## Decision

**A criterion whose proof lives in a PR body may be CLOSED OVER by the LEAD, with a note
naming it unsatisfiable and why. It is NOT flipped to met.**

Operationally: leave `met` false, record the reason in `close_reason`, and close the row
honestly short. The row's ratio stays truthful — an 8/9 that reads 8/9.

A conforming specimen predates this record: `dr-w2-s6` is closed at **8/9**, its
`close_reason` reading *"Criterion 6 (the PR body states the dr-w2-s2 two halves line) is
UNSATISFIABLE and is closed over on the record, not flipped."* This ADR ratifies the
practice rather than inventing one.

## Why not the alternatives

| Option | Verdict |
|---|---|
| **Ban PR-body criteria in the authoring rubric** | REJECTED — a real constraint on authors that invites the same requirement in vaguer wording, which is *harder to audit than the ban is worth*. |
| **Stamp them pre-merge** | REJECTED as the sole rule — correct when someone remembers, but it fails exactly when the wave is busy, which is when the class appears. |
| **Flip to met with a note** | REJECTED — see below; it destroys the record. |

The flip is the tempting option and the damaging one. A laundered **9/9** claims a proof
that does not exist and erases the evidence that the criterion was unpayable. Preserving
information beats tidying it away: a visibly short row is a true row.

## Known weakness — stated, not hidden

**This rule ends the deadlock, not the authoring.** The shape keeps getting written; nothing
here stops an author from writing another one tomorrow, and every instance still costs a
lead act to close over. What it buys is that no such criterion can stall a row — or a chain
of sweep orders — indefinitely.

If the shape's *frequency* ever becomes the dominant cost, revisit the rejected ban with
measurements: how many are authored per wave, and how many lead-acts they cost.
