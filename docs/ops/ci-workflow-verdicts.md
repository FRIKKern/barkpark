<!-- doc-tier: agent | canonical-for: ci-workflow-venue-verdicts | budget: 2000tok -->
# CI workflow venue verdicts

Companion to `docs/ops/ci-cost-baseline.md` (method, totals, census). Policy: **a PR runs only what
can block it or finishes under 60 s.** Owner of every verdict is lead-gates unless stated.

**Do not optimise by duration.** Cost is `duration x frequency`; frequency spans three orders of
magnitude here (1,428 to 0), duration one (3.82 to 0.05 min). Sorting by `min/exec` starts you on
the cheapest half.

`PR` is an exact census of **four days** (2026-08-30..09-02) — a count, never a workflow property:
see the 2026-09-06 correction. `min/exec` is sampled from six recent PR runs, thin for anything that
skips often. `push` counts live with the census in `ci-cost-baseline.md`.

| verdict | means |
|---|---|
| KEEP-REQ | produces a required context; a filter emits no check run and deadlocks it |
| KEEP-CHEAP | under 60 s per execution — venue not worth a sign-off |
| CANDIDATE | over 60 s but infrequent; move for per-PR latency, not job-minutes |
| MOVE | ruled and in flight |
| DORMANT | fired 0 times in a window of at least 3x its observed firing period (see below) |
| UNMEASURED | every sampled job was zero-step; re-measure over 20+ runs before ruling |

| workflow | PR | min/exec | verdict |
|---|---|---|---|
| `pr-task-gate.yml` | 1428 | 0.0 | KEEP-REQ |
| `cloud.yml` | 1227 | 0.4 | KEEP-REQ |
| `compose-smoke.yml` | 1227 | 0.0 | UNMEASURED |
| `console-harness.yml` | 1227 | 0.34 | KEEP-REQ |
| `elixir.yml` | 1227 | 1.25 | KEEP-REQ |
| `reland-check.yml` | 1227 | 0.0 | UNMEASURED |
| `required-checks-drift.yml` | 1227 | 0.0 | MOVE |
| `security.yml` | 1227 | 0.35 | KEEP-CHEAP |
| `doc-gates.yml` | 1115 | 0.0 | UNMEASURED |
| `architecture.yml` | 807 | 0.27 | KEEP-CHEAP |
| `go-tests.yml` | 515 | 0.48 | KEEP-CHEAP |
| `pr-meta.yml` | 407 | 0.0 | UNMEASURED |
| `task-lease-renew.yml` | 308 | 0.27 | KEEP-CHEAP |
| `go-format.yml` | 212 | 0.44 | KEEP-CHEAP |
| `shell-harnesses.yml` | 193 | 0.33 | KEEP-CHEAP |
| `twoslash.yml` | 53 | 1.45 | MOVE (2026-09-05) |
| `js-tests.yml` | 51 | 1.59 | CANDIDATE |
| `typedoc.yml` | 51 | 0.92 | KEEP-CHEAP |
| `mobile.yml` | 43 | 1.24 | CANDIDATE |
| `grip-suite.yml` | 40 | 2.7 | MOVE (2026-09-05) |
| `ci.yml` | 33 | 1.2 | CANDIDATE |
| `search-template-gates.yml` | 33 | 0.18 | KEEP-CHEAP |
| `sheet-grid-js.yml` | 33 | 0.0 | UNMEASURED |
| `deploy-harnesses.yml` | 32 | 3.82 | MOVE (2026-09-05) |
| `paper-editor.yml` | 28 | 0.0 | UNMEASURED |
| `crown-reconcile.yml` | 26 | 0.0 | UNMEASURED |
| `pdrender-wasm.yml` | 23 | 0.47 | KEEP-CHEAP |
| `stale-verdict-watch.yml` | 19 | 0.46 | KEEP-CHEAP |
| `create-quickstart-smoke.yml` | 14 | 0.0 | UNMEASURED |
| `search-starter-smoke.yml` | 10 | 1.09 | CANDIDATE |
| `astro-finder-drift.yml` | 5 | 0.16 | KEEP-CHEAP |
| `web-fork-drift.yml` | 4 | 0.42 | KEEP-CHEAP |
| `astro-search-finder-test.yml` | 3 | 0.21 | KEEP-CHEAP |
| `connectors.yml` | 3 | 1.48 | CANDIDATE |
| `plugin-node.yml` | 3 | 0.05 | KEEP-CHEAP |
| `research-coverage-suite.yml` | 3 | 0.25 | KEEP-CHEAP |
| `breakglass-watch.yml` | 2 | 0.21 | KEEP-CHEAP |
| `chronicle-paper.yml` | 2 | 0.45 | KEEP-CHEAP |
| `weekly-changelog.yml` | 2 | 0.47 | KEEP-CHEAP |
| `bp-graph-drift.yml` | 1 | 0.12 | KEEP-CHEAP |
| `sdk-tests.yml` | 1 | 0.28 | KEEP-CHEAP |
| `hundesteder.yml` | 0 | 0.53 | KEEP-CHEAP |
| `main-gate-watch.yml` | 0 | 0.11 | KEEP-CHEAP |
| `studio-journey-smoke.yml` | 0 | 1.68 | CANDIDATE |
| `vendored-assets.yml` | 0 | 0.28 | KEEP-CHEAP |
| `windows-smoke.yml` | 0 | 0.33 | KEEP-CHEAP |

## DISCHARGED 2026-09-11 (task-004328587a739530) — the four standing reds

Re-derived against `origin/main` `4a315265b`; commands and output are quoted in that PR.

| workflow | verdict | anchor |
|---|---|---|
| `doc-gates.yml` | FIXED 2026-09-03 | `e1e970346` (#15483): `check-doc-budgets.sh:767` asserts `-ne 0`, not the bash-3.2-only `70` |
| `go-format.yml` | fixed 2026-09-02 by `e0f420ea7` (#15479, an EMPTY merge); **RED AGAIN 2026-09-11** | `scripts/go-format-drift-ceiling.sh` exits 1 at `4a315265b`, 3 off-roster files |
| `security.yml` | FIXED — main's pending run is no longer evicted | `security.yml:152`, per-SHA concurrency group |
| `deploy.yml` | FIXED 2026-09-06 — cannot succeed while `converged=false` | `deploy.yml:1932` `exit "$verdict_rc"`; set false at `:1849`/`:1873` |

## CORRECTED 2026-09-06 — the five DORMANT rows were a FOUR-DAY artifact

Four days cannot establish dormancy; over 30 days all five fired, two with reds. **Retire none.**
`ci-measure.sh --census` now refuses DORMANT under a window below `3x` the observed firing period and
carries that window inline. Full correction: [history](ci-workflow-verdicts-history.md).

## CORRECTED 2026-09-03 — `architecture` was GREEN AND BLIND

The full correction (why a never-red tripwire whose selftest dies behind `continue-on-error` is disconnected, not quiet, and what was re-verdicted) is preserved verbatim in [ci-workflow-verdicts-history.md](ci-workflow-verdicts-history.md); the roster below carries the corrected verdict.

## MOVED 2026-09-05 (task-33742276cf0a35b1)

Non-test CANDIDATEs leave the PR path; `js-tests`, `mobile`, `ci`, `search-starter-smoke`, `connectors`
STAY (they test the code the PR touches). Watcher = the `Report main-push failure to a human` job
(`file-ci-failure-issue.sh`, one idempotent issue per key; close it when main is green).

| workflow | venue now | owner | issue key |
|---|---|---|---|
| `deploy-harnesses.yml` | push:main + nightly 03:20Z + dispatch | lead-gates | `deploy-harnesses-main` |
| `grip-suite.yml` | push:main + nightly 03:25Z + dispatch (PR arm removed) | lead-gates | `grip-suite` |
| `twoslash.yml` | push:main + nightly 03:30Z + dispatch | lead-gates | `twoslash-main` |

## ADDED 2026-09-05 (task-bc9fe6dc29d0b979) — `search-template-gates.yml` gains a main arm

Venue now **push:main (path-UNFILTERED) + the unchanged PR arm**, owner lead-gates, issue key
`search-template-gates-main`. It was `pull_request`-only, so main was never measured and #16174
merged while `Vendored SDK freshness` was red, shipping a stale vendored `barkpark-core.tgz` to every
scaffolded user. It stays ADVISORY. **If promoted to required, register an AGGREGATOR context, never
a paths-filtered leaf job name** — one that emits no check run on a filtered-out PR waits forever.

**Fence collision — trigger and remedy live in different trees.** `Vendored SDK freshness` fires on
`js/packages/{core,react}/**`, but its only remedy writes to `templates/**`:
`bash scripts/recut-vendor-tarballs.sh`, then commit the re-cut `templates/*/vendor/*.tgz` and
`templates/VENDOR-STAMP.json` **in the same PR**. A lane fenced out of `templates/**` cannot green it.

## The three that need words

**`required-checks-drift` — MOVE, in flight as #15663.** ~3,500 job-minutes across 1,227 PR runs for
a question about the repo's state, not the PR's diff. Push-to-main, nightly cron, plus a PR arm keyed
to its own inputs. Watcher: main's own push run and the cron. Its 0.17-min workflow linter stays
UNCONDITIONAL — its subject is the whole workflow tree, so a diff-keyed condition would blind it to a
file any PR can poison.

**The four KEEP-REQ cannot be filtered at all.** A required context emitting no check run routes to
`is expected.` forever. Their per-push cost is their Dispatch job, which is why the blobless-checkout
child pays across all of them at once rather than one workflow at a time.

**The Elixir `Test` job is not a candidate.** 992 s, of which **827 s is `mix test` itself** over
~17,000 tests (run 33671977469; compile 6 s cached, containers 33 s, libxml2 21 s, checkout 26 s).
Honest work. The only levers are fewer runs — the dispatcher and push discipline — and not starting
it for pushes that will be superseded. Partitioning cuts wall time but not job-minutes, and
job-minutes are the ceiling, so it is refused.

