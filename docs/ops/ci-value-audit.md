<!-- doc-tier: agent | canonical-for: ci-workflow-value-audit | budget: 2200tok -->
# CI value audit — did the red mean anything?

Cost is measured in `docs/ops/ci-cost-baseline.md`. This is the other half: **value**. Produced by
`bash scripts/ci-measure.sh --value-audit --since 2026-08-03` (30 days, pull_request runs).

## The classification rule

| bucket | rule |
|---|---|
| RERUN-GREEN | the run went green on a LATER ATTEMPT of the same run, or a later run on the same head sha. Nothing about the code changed, so the red carried no information. **This is a flake and can never be a catch.** |
| CATCH-CANDIDATE | red, then green on a LATER head of the same PR. It **may** have caught something. Reported as a candidate, not a catch — proving it needs a per-workflow diff test this mode does not do. |
| RED-UNRESOLVED | red with no later green at all. Usually a persistently broken check, not a catch. |
| NEVER-RED | zero reds. Not automatically useless, but it has demonstrated nothing. |

Counting a rerun-green as a catch is not a rounding error, it is **backwards**: a flaky check reruns
green often and would score the highest catch rate in the repo. Selftest arms v1, v1b and v2 exist to
keep those buckets apart, and v1 reds if the classifier is mutated to merge them.

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

## What the real flake list is

- **`elixir` — four genuinely flaky modules**: `BridgeSandboxCascadeTest` (x4), `ClaudeChatTest` (x4),
  `TasksMergeGateNagTest` (x3), `StudioLiveSheetPresenceTest` (x2).
- **`console-harness` — one flaky INSTRUMENT, not a flaky suite**: the Overflow guard's
  `READY HOST NOT PAINTED` exit 2 owns all seven.
- **`validation-perf`** cancels and reds the Elixir aggregate seven times.

## The number that dwarfs all of it

**52% of all PR reds in 14 days — 631 of 1,207 — were main's own defect, inherited by every open PR**,
in nine named clusters. No amount of per-workflow tuning touches that; it is a main-red circuit-breaker
problem, filed separately.

And **`doc-gates` is the largest single noise source in the repo**: 466 reds in 15 days, **78%
unresolved** (the branch never goes green), and **zero check-run annotations on all 60 sampled** — an
author who sees the red must open the log to learn anything. A gate that reds 31 times a day, is
ignored 78% of the time, and says nothing on the check API is training the fleet to ignore reds
generally.

## The lesson worth more than the numbers

A classification rule carries assumptions about **what its subject consumes**. "Nothing changed, so the
red meant nothing" is only true for a check whose input is the thing that did not change. Before
applying a uniform rule across a roster, ask what each member reads — `pr-task-gate` reads a ledger and
a PR body, and it was the one case the rule inverted.

## Full table

| workflow | runs | reds | rerun-green | catch-cand | unresolved | verdict |
|---|---|---|---|---|---|---|
| `doc-gates.yml` | 300 | 56 | 0 | 0 | 56 | RED-UNRESOLVED |
| `js-tests.yml` | 171 | 45 | 0 | 45 | 0 | CATCH-CANDIDATE |
| `go-format.yml` | 300 | 31 | 0 | 27 | 4 | CATCH-CANDIDATE |
| `pr-task-gate.yml` | 300 | 24 | 8 | 7 | 17 | FLAKE-DOMINANT |
| `compose-smoke.yml` | 300 | 21 | 1 | 1 | 20 | CATCH-CANDIDATE |
| `elixir.yml` | 300 | 18 | 8 | 10 | 8 | CATCH-CANDIDATE |
| `security.yml` | 300 | 13 | 1 | 2 | 11 | CATCH-CANDIDATE |
| `shell-harnesses.yml` | 300 | 7 | 2 | 1 | 6 | FLAKE-DOMINANT |
| `pr-meta.yml` | 300 | 5 | 2 | 1 | 4 | FLAKE-DOMINANT |
| `hundesteder.yml` | 8 | 4 | 0 | 4 | 0 | CATCH-CANDIDATE |
| `cloud.yml` | 300 | 3 | 7 | 2 | 1 | FLAKE-DOMINANT |
| `mobile.yml` | 101 | 3 | 1 | 3 | 0 | CATCH-CANDIDATE |
| `sheet-grid-js.yml` | 65 | 3 | 0 | 3 | 0 | CATCH-CANDIDATE |
| `chronicle-paper.yml` | 42 | 3 | 0 | 3 | 0 | CATCH-CANDIDATE |
| `console-harness.yml` | 300 | 2 | 6 | 1 | 1 | FLAKE-DOMINANT |
| `crown-reconcile.yml` | 66 | 2 | 0 | 2 | 0 | CATCH-CANDIDATE |
| `grip-suite.yml` | 51 | 2 | 0 | 0 | 2 | RED-UNRESOLVED |
| `bp-graph-drift.yml` | 5 | 2 | 0 | 2 | 0 | CATCH-CANDIDATE |
| `required-checks-drift.yml` | 300 | 1 | 2 | 0 | 1 | FLAKE-DOMINANT |
| `search-starter-smoke.yml` | 29 | 1 | 0 | 1 | 0 | CATCH-CANDIDATE |
| `vendored-assets.yml` | 3 | 1 | 0 | 1 | 0 | CATCH-CANDIDATE |
| `architecture.yml` | 300 | 0 | 2 | 0 | 0 | NEVER-RED |
| `go-tests.yml` | 300 | 0 | 2 | 0 | 0 | NEVER-RED |
| `reland-check.yml` | 300 | 0 | 2 | 0 | 0 | NEVER-RED |
| `task-lease-renew.yml` | 300 | 0 | 3 | 0 | 0 | NEVER-RED |
| `twoslash.yml` | 170 | 0 | 0 | 0 | 0 | NEVER-RED |
| `typedoc.yml` | 168 | 0 | 0 | 0 | 0 | NEVER-RED |
| `paper-editor.yml` | 68 | 0 | 0 | 0 | 0 | NEVER-RED |
| `ci.yml` | 67 | 0 | 0 | 0 | 0 | NEVER-RED |
| `search-template-gates.yml` | 59 | 0 | 0 | 0 | 0 | NEVER-RED |
| `deploy-harnesses.yml` | 56 | 0 | 0 | 0 | 0 | NEVER-RED |
| `stale-verdict-watch.yml` | 49 | 0 | 1 | 0 | 0 | NEVER-RED |
| `pdrender-wasm.yml` | 41 | 0 | 0 | 0 | 0 | NEVER-RED |
| `create-quickstart-smoke.yml` | 24 | 0 | 0 | 0 | 0 | NEVER-RED |
| `astro-search-finder-test.yml` | 21 | 0 | 0 | 0 | 0 | NEVER-RED |
| `astro-finder-drift.yml` | 17 | 0 | 0 | 0 | 0 | NEVER-RED |
| `connectors.yml` | 11 | 0 | 0 | 0 | 0 | NEVER-RED |
| `sdk-tests.yml` | 8 | 0 | 0 | 0 | 0 | NEVER-RED |
| `weekly-changelog.yml` | 5 | 0 | 0 | 0 | 0 | NEVER-RED |
| `main-gate-watch.yml` | 4 | 0 | 0 | 0 | 0 | NEVER-RED |
| `research-coverage-suite.yml` | 4 | 0 | 0 | 0 | 0 | NEVER-RED |
| `web-fork-drift.yml` | 4 | 0 | 0 | 0 | 0 | NEVER-RED |
| `plugin-node.yml` | 3 | 0 | 0 | 0 | 0 | NEVER-RED |
| `breakglass-watch.yml` | 2 | 0 | 0 | 0 | 0 | NEVER-RED |
| `windows-smoke.yml` | 1 | 0 | 0 | 0 | 0 | NEVER-RED |

## Flake evidence

The first pass listed run ids here as flakes. **That list is withdrawn**: `cloud`'s were reruns of
cancelled attempts and `pr-task-gate`'s were authors fixing a PR body. The surviving flake evidence is
the four modules and one instrument named above, plus `pr-task-gate`'s four INFRA reds. Re-derive with
`--value-audit`, which now splits rerun-after-cancel from rerun-after-failure.

## Two honest limits

**An in-place rerun is invisible as two runs, and the first pass of this audit missed every one.**
`gh run rerun` re-runs the SAME run id and updates it, so a red-then-green rerun never appears as a
second row. The first pass reported `rerun=0` for **every** workflow — not credible, and that was the
tell. `run_attempt > 1` with a green conclusion is the same event seen correctly. Arm v1b pins it.

**A NEVER-RED row with a non-zero rerun count is a window edge**, not a contradiction: the failing
attempt fell outside the 30-day window while the successful retry landed inside it.

