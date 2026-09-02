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

## THE FINDING: three of the four required contexts are flake-dominant

`pr-task-gate`, `cloud` and `console-harness` produce three of the four contexts that block every
merge, and each goes green on a rerun **more often** than it is followed by a real fix:

| required context | reds | rerun-green | catch-candidate |
|---|---|---|---|
| `pr-task-gate` | 24 | **8** | 7 |
| `cloud` | 3 | **7** | 2 |
| `console-harness` | 2 | **6** | 1 |
| `elixir` | 18 | 8 | 10 |

A required check that usually passes on a retry teaches every author the same lesson — press rerun —
and that habit is indistinguishable from the one that ships a real regression. This is the highest-
value target in the goal, and it is a **signal** problem, not a cost one.

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

## Flake evidence, by run id

- pr-task-gate.yml: red 33627970221 -> green attempt 2 (same sha); red 33657154755 -> green attempt 2 (same sha); red 33659858318 -> green attempt 2 (same sha)
- compose-smoke.yml: red 33655517138 -> green attempt 2 (same sha)
- elixir.yml: red 33627970028 -> green attempt 2 (same sha); red 33655517077 -> green attempt 2 (same sha); red 33660429420 -> green attempt 2 (same sha)
- security.yml: red 33655517245 -> green attempt 2 (same sha)
- shell-harnesses.yml: red 33567185204 -> green attempt 2 (same sha); red 33567517159 -> green attempt 2 (same sha)
- pr-meta.yml: red 33655516869 -> green attempt 2 (same sha); red 33661709684 -> green attempt 2 (same sha)
- cloud.yml: red 33627970122 -> green attempt 2 (same sha); red 33660330989 -> green attempt 2 (same sha); red 33660345861 -> green attempt 2 (same sha)
- mobile.yml: red 33655517135 -> green attempt 2 (same sha)

## Two honest limits

**An in-place rerun is invisible as two runs, and the first pass of this audit missed every one.**
`gh run rerun` re-runs the SAME run id and updates it, so a red-then-green rerun never appears as a
second row. The first pass reported `rerun=0` for **every** workflow — not credible, and that was the
tell. `run_attempt > 1` with a green conclusion is the same event seen correctly. Arm v1b pins it.

**A NEVER-RED row with a non-zero rerun count is a window edge**, not a contradiction: the failing
attempt fell outside the 30-day window while the successful retry landed inside it.

