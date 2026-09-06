<!-- doc-tier: cold | canonical-for: ci-workflow-verdicts-history | budget: 1400tok -->
# CI workflow venue verdicts — dated corrections (history)

> HISTORICAL RECORD (2026-09-03) — the correction below was written on that date against the runs it names. Re-derive from current runs; never quote the recorded counts as current.

Moved verbatim out of [ci-workflow-verdicts.md](ci-workflow-verdicts.md) — the 2026-09-03 correction on 2026-09-05, the 2026-09-05 `search-template-gates` record on 2026-09-06 — each time that page crossed its 2000tok header. The live roster, the standing verdicts, and the operational residue of each record (venue, owner, issue key, the fence-collision recipe) stay there. `doc-tier: cold` is budget-exempt by design (`scripts/check-doc-budgets.sh`), so the header here is declarative.

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

## ADDED 2026-09-05 (task-bc9fe6dc29d0b979) — `search-template-gates.yml` gains a main arm

Not a move: the PR arm and its `paths:` list are unchanged. `search-template-gates.yml` was
`pull_request`-only, so `gh run list --workflow=search-template-gates.yml --branch main` returned an
EMPTY list — main was never measured, and #16174 merged at 12:20Z while `Vendored SDK freshness` was
red, shipping a stale vendored `barkpark-core.tgz` to every scaffolded user. Trigger change
authorised by main under task-33742276cf0a35b1.

| workflow | venue now | owner | issue key |
|---|---|---|---|
| `search-template-gates.yml` | push:main (path-UNFILTERED) + the unchanged PR arm | lead-gates | `search-template-gates-main` |

The main arm is deliberately path-unfiltered: the vendored tarballs are a FROZEN artifact that rots
against a moving source tree, so a `paths:` filter would only move the vacuous green one hop, from
"main is never measured" to "main is not measured when untouched". It stays ADVISORY — it reds its
own check-run and cannot stop a merge. **If it is ever promoted to required, register an AGGREGATOR
context, never one of the paths-filtered leaf job names**: a required context that emits no check run
on a filtered-out PR waits for status forever.

**Fence collision — the trigger and the remedy live in different trees.** `Vendored SDK freshness`
fires on `js/packages/{core,react}/**`, but its only remedy writes to `templates/**`:
`bash scripts/recut-vendor-tarballs.sh`, then commit the re-cut `templates/*/vendor/*.tgz` and
`templates/VENDOR-STAMP.json`. The SDK lane must run that script **in the same PR** as the
js/packages change; a lane fenced out of `templates/**` cannot green this gate and will wrongly
conclude the gate is broken.
