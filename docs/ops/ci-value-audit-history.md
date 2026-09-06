<!-- doc-tier: cold | canonical-for: ci-value-audit-history | budget: 700tok -->
# CI value audit — dated corrections (history)

> HISTORICAL RECORD (2026-09-03) — written against the runs it names. Re-derive from current
> runs; never quote the recorded counts as current.

Moved verbatim out of [ci-value-audit.md](ci-value-audit.md) on 2026-09-06 when that page
crossed its 2200tok header; the live rule, roster and standing verdicts stay there.

## CORRECTED 2026-09-03 — the first headline here was WRONG

**This file first said "three of the four required contexts are flake-dominant". That was wrong, and
the error was in the rule, not the arithmetic.**

The rule read: *nothing about the code changed between the red and the green, so the red carried no
information.* It has an unstated assumption — **that the check's input is the code.** That holds for
`elixir`, `cloud` and `console-harness`. It is false for `pr-task-gate`, whose inputs are the **PR
description and the ledger**, neither of which is in any commit. When an author fixes a missing
`Task:` trailer and re-runs, **the rerun IS the fix**, on the same sha, and this file scored it as a
flake.

Measured over the full 15-day population (1,207 PR reds) rather than the capped 300-run window:

| claim in the first pass | corrected |
|---|---|
| `pr-task-gate` flake-dominant, 8 of 24 | **flake rate 4 of 107 = 3.7%** — only the INFRA/ledger-unreachable class (runs 32838427181, 32671727320, 32340738580, 32315588293). 21 of its 34 rerun-greens said "no task reference found" and the author edited the PR body. |
| `cloud` 7 rerun-greens | **0 flakes.** All seven were reruns of **CANCELLED** attempts — three of them one dispatcher-cancellation event. A cancelled attempt produced no verdict, so there is no red to explain. |
| the gates do not earn their keep | **they do.** On the honest subset (red and green heads ≤2 commits apart) the catch rate is `cloud` 18/20, `elixir` 28/39, `console-harness` 4/5. |

**Why the ≤2-commit subset is the honest one:** median commits between a red head and the next green
head is 35 for `elixir` and 27 for `pr-task-gate`. A 35-commit gap contains the whole rest of the PR,
so "the diff touched source" is true by construction and proves nothing.

**The diff test is INAPPLICABLE to `pr-task-gate`, not failed by it.** 5 of its 19 tight-gap cases have
a literally empty diff — a force-pushed commit-message amend, which is exactly what fixing a trailer
looks like.
