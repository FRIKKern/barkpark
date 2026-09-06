<!-- doc-tier: agent | canonical-for: ci-workflow-value-audit | budget: 2200tok -->
# CI value audit — did the red mean anything?

Cost is measured in `docs/ops/ci-cost-baseline.md`. This is the other half: **value**. Produced by
`bash scripts/ci-measure.sh --value-audit --since 2026-08-03` (30 days, pull_request runs).

## CORRECTED 2026-09-06 — every row reading `300` is a CEILING, not a count

The collector paged three times at `per_page=100`, newest first, and said nothing when the third page
came back full. A `300` row therefore covers its newest 300 runs — **0.51 d** for `task-lease-renew`,
**0.73 d** for `doc-gates` — while `windows-smoke`'s one row covers all 30 d. Direction survives
(`doc-gates` is understated if anything); **no row-to-row ratio below is supported.** Fixed: the
collector pages to the window, prints `span_d`, and puts a loud cap notice ABOVE the table when a
workflow hits GitHub's own 1000-item ceiling. Arms `t1`-`t3`.

**The classifier now reads the assumption instead of assuming it.** The retraction below reached this
prose on 2026-09-03 and never the instrument, which printed `FLAKE-DOMINANT` for `pr-task-gate` for
three more days. A workflow reading `github.event.pull_request.{body,title,labels}` — derived from
the workflow file, not a typed list; `pr-task-gate`, `reland-check`, `task-lease-renew` today — is
verdicted `INPUTS-OUTSIDE-SHA`, never `FLAKE-DOMINANT`. Arms `v7`-`v7c`. **Honest limit:** a gate
reading the task ledger is the same class and is not yet detected.

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

"Three of the four required contexts are flake-dominant" was wrong, and the error was in the
rule, not the arithmetic: it assumed the check's input is the code. The full correction — the
3.7% `pr-task-gate` flake rate, `cloud`'s seven cancelled-attempt reruns, the honest ≤2-commit
catch rates, and why the diff test is INAPPLICABLE to `pr-task-gate` rather than failed by it —
is preserved verbatim in [ci-value-audit-history.md](ci-value-audit-history.md). The rule it
produced is now enforced by the classifier, not just written down (see above).

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

A classification rule carries assumptions about **what its subject consumes**. "Nothing changed, so
the red meant nothing" holds only for a check whose input is the thing that did not change. It cost
three days to learn that fixing the prose does not fix the instrument.

## Full table

| workflow | runs | reds | rerun-green | catch-cand | unresolved | verdict |
|---|---|---|---|---|---|---|
| `doc-gates.yml` | 300 | 56 | 0 | 0 | 56 | RED-UNRESOLVED |
| `js-tests.yml` | 171 | 45 | 0 | 45 | 0 | CATCH-CANDIDATE |
| `go-format.yml` | 300 | 31 | 0 | 27 | 4 | CATCH-CANDIDATE |
| `pr-task-gate.yml` | 300 | 24 | 8 | 7 | 17 | INPUTS-OUTSIDE-SHA |
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
| `stale-verdict-watch.yml` | 49 | 0 | 1 | 0 | 0 | NEVER-RED |

**NEVER-RED with nothing else in any column** (runs, and zero reds / rerun-greens /
candidates / unresolved): `twoslash.yml` 170, `typedoc.yml` 168, `paper-editor.yml` 68, `ci.yml` 67, `search-template-gates.yml` 59, `deploy-harnesses.yml` 56, `pdrender-wasm.yml` 41, `create-quickstart-smoke.yml` 24, `astro-search-finder-test.yml` 21, `astro-finder-drift.yml` 17, `connectors.yml` 11, `sdk-tests.yml` 8, `weekly-changelog.yml` 5, `main-gate-watch.yml` 4, `research-coverage-suite.yml` 4, `web-fork-drift.yml` 4, `plugin-node.yml` 3, `breakglass-watch.yml` 2, `windows-smoke.yml` 1.

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

