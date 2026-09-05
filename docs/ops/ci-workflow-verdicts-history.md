<!-- doc-tier: cold | canonical-for: ci-workflow-verdicts-history | budget: 900tok -->
# CI workflow venue verdicts — dated corrections (history)

> HISTORICAL RECORD (2026-09-03) — the correction below was written on that date against the runs it names. Re-derive from current runs; never quote the recorded counts as current.

Moved verbatim out of [ci-workflow-verdicts.md](ci-workflow-verdicts.md) on 2026-09-05 when that page crossed its 2000tok header (8611 B > 8000 B); the live roster and its standing verdicts stay there.

## CORRECTED 2026-09-03 — `architecture` was GREEN AND BLIND

I argued that for a tripwire, never-red is the design goal, so `architecture`'s zero reds over 300 runs
were the evidence FOR it. **That reasoning was right in general and wrong about this workflow.**

`architecture` is silent because **it cannot see**: its selftest dies in 5 of 5 runs, behind
`continue-on-error`, so the harness that proves the gate can still fail is itself failing invisibly.
A gate that has lost the ability to red is not a quiet scream, it is a disconnected one — and from the
outside the two look identical, which is exactly why "never-red is fine for a tripwire" must never be
applied without checking that the tripwire still works. Filed as `task-6891e8f620c1bdea`.

**The general rule survives; the instance does not.**

### The sweep, run 2026-09-03 — the other seven CAN see

I re-earned the list rather than leaving it on the argument that just failed. For each of the seven
tripwires I cleared on "never-red is the design goal", the test is **does its own proving step pass on
the newest completed run**, not what its red rate is.

| tripwire | proving step | newest completed run |
|---|---|---|
| `breakglass-watch` | Prove the glass can be shown open | success |
| `main-gate-watch` | Prove the watch can lose both ways | success |
| `stale-verdict-watch` | Prove the verdict can be shown wrong | success (and its check step is RED right now — it is doing its job) |
| `astro-finder-drift` | Self-test the tripwire | success |
| `web-fork-drift` | Self-test the tripwire | success |
| `search-template-gates` | Self-test the tripwire (its negative half must red) | success, all three jobs |
| `reland-check` | `reland_check.test.sh` + `reland_loudfail.test.sh`, in `shell-harnesses.yml` | 76 and 7 cases, both pass |

**7 of 7 can still fail. `architecture` was the only blind one.**

Two wrong intermediate conclusions I caught before publishing, both worth the warning:
- A grep for `selftest` found nothing in four of them and I nearly called them unproven. Their proving
  steps are named *"Prove the glass can be shown open"* and *"Prove the watch can lose both ways"* —
  **the discipline was there, the word was not.** Grepping for a keyword measures vocabulary.
- I then found no harness call inside `reland-check.yml` and nearly reported it blind. Its proof runs
  from `shell-harnesses.yml`, which is the documented home for harnesses no other lane executes — and
  `reland-check.yml` is itself in that workflow's paths, so editing the gate re-runs its proof. **An
  absence claim scoped to one file is not an absence claim.**

 The test that separates them is not the red rate,
it is whether the gate's own selftest passes. Apply that to the other seven tripwires before trusting
their silence.

`reland-check` (2,188 runs) and `architecture` (1,402 runs) are both never-red in 14 days, not
required, and carry no written rationale — they are the two strongest RETIRE-OR-MOVE candidates once
`architecture` can see again.

