<!-- doc-tier: agent | canonical-for: ci-workflow-venue-verdicts | budget: 2000tok -->
# CI workflow venue verdicts

Companion to `docs/ops/ci-cost-baseline.md` (method, totals, census). Policy: **a PR runs only what
can block it or finishes under 60 s.** Owner of every verdict is lead-gates unless stated.

**Do not optimise by duration.** Cost is `duration x frequency`; frequency spans three orders of
magnitude here (1,428 to 0), duration one (3.82 to 0.05 min). Sorting by `min/exec` starts you on
the cheapest half.

`PR`/`push` are an exact census (2026-08-30..09-02). `min/exec` is sampled from six recent PR runs
and is thin for anything that skips often.

| verdict | means |
|---|---|
| KEEP-REQ | produces a required context; a filter emits no check run and deadlocks it |
| KEEP-CHEAP | under 60 s per execution — venue not worth a sign-off |
| CANDIDATE | over 60 s but infrequent; move for per-PR latency, not job-minutes |
| MOVE | ruled and in flight |
| DORMANT | declared PR-triggered, fired 0 times — stale declaration, not saved minutes |
| UNMEASURED | every sampled job was zero-step; re-measure over 20+ runs before ruling |

| workflow | PR | push | min/exec | verdict |
|---|---|---|---|---|
| `pr-task-gate.yml` | 1428 | 0 | 0.0 | KEEP-REQ |
| `cloud.yml` | 1227 | 626 | 0.4 | KEEP-REQ |
| `compose-smoke.yml` | 1227 | 626 | 0.0 | UNMEASURED |
| `console-harness.yml` | 1227 | 626 | 0.34 | KEEP-REQ |
| `elixir.yml` | 1227 | 626 | 1.25 | KEEP-REQ |
| `reland-check.yml` | 1227 | 0 | 0.0 | UNMEASURED |
| `required-checks-drift.yml` | 1227 | 626 | 0.0 | MOVE |
| `security.yml` | 1227 | 626 | 0.35 | KEEP-CHEAP |
| `doc-gates.yml` | 1115 | 546 | 0.0 | UNMEASURED |
| `architecture.yml` | 807 | 0 | 0.27 | KEEP-CHEAP |
| `go-tests.yml` | 515 | 120 | 0.48 | KEEP-CHEAP |
| `pr-meta.yml` | 407 | 155 | 0.0 | UNMEASURED |
| `task-lease-renew.yml` | 308 | 0 | 0.27 | KEEP-CHEAP |
| `go-format.yml` | 212 | 109 | 0.44 | KEEP-CHEAP |
| `shell-harnesses.yml` | 193 | 382 | 0.33 | KEEP-CHEAP |
| `twoslash.yml` | 53 | 0 | 1.45 | CANDIDATE |
| `js-tests.yml` | 51 | 27 | 1.59 | CANDIDATE |
| `typedoc.yml` | 51 | 26 | 0.92 | KEEP-CHEAP |
| `mobile.yml` | 43 | 14 | 1.24 | CANDIDATE |
| `grip-suite.yml` | 40 | 27 | 2.7 | CANDIDATE |
| `ci.yml` | 33 | 14 | 1.2 | CANDIDATE |
| `search-template-gates.yml` | 33 | 0 | 0.18 | KEEP-CHEAP |
| `sheet-grid-js.yml` | 33 | 12 | 0.0 | UNMEASURED |
| `deploy-harnesses.yml` | 32 | 0 | 3.82 | CANDIDATE |
| `paper-editor.yml` | 28 | 7 | 0.0 | UNMEASURED |
| `crown-reconcile.yml` | 26 | 626 | 0.0 | UNMEASURED |
| `pdrender-wasm.yml` | 23 | 10 | 0.47 | KEEP-CHEAP |
| `stale-verdict-watch.yml` | 19 | 626 | 0.46 | KEEP-CHEAP |
| `create-quickstart-smoke.yml` | 14 | 5 | 0.0 | UNMEASURED |
| `search-starter-smoke.yml` | 10 | 7 | 1.09 | CANDIDATE |
| `astro-finder-drift.yml` | 5 | 2 | 0.16 | KEEP-CHEAP |
| `web-fork-drift.yml` | 4 | 2 | 0.42 | KEEP-CHEAP |
| `astro-search-finder-test.yml` | 3 | 2 | 0.21 | KEEP-CHEAP |
| `connectors.yml` | 3 | 1 | 1.48 | CANDIDATE |
| `plugin-node.yml` | 3 | 1 | 0.05 | KEEP-CHEAP |
| `research-coverage-suite.yml` | 3 | 3 | 0.25 | KEEP-CHEAP |
| `breakglass-watch.yml` | 2 | 626 | 0.21 | KEEP-CHEAP |
| `chronicle-paper.yml` | 2 | 0 | 0.45 | KEEP-CHEAP |
| `weekly-changelog.yml` | 2 | 0 | 0.47 | KEEP-CHEAP |
| `bp-graph-drift.yml` | 1 | 1 | 0.12 | KEEP-CHEAP |
| `sdk-tests.yml` | 1 | 1 | 0.28 | KEEP-CHEAP |
| `hundesteder.yml` | 0 | 0 | 0.53 | DORMANT |
| `main-gate-watch.yml` | 0 | 0 | 0.11 | DORMANT |
| `studio-journey-smoke.yml` | 0 | 0 | 1.68 | DORMANT |
| `vendored-assets.yml` | 0 | 0 | 0.28 | DORMANT |
| `windows-smoke.yml` | 0 | 0 | 0.33 | DORMANT |

## CORRECTED 2026-09-03 — `architecture` was GREEN AND BLIND

I argued that for a tripwire, never-red is the design goal, so `architecture`'s zero reds over 300 runs
were the evidence FOR it. **That reasoning was right in general and wrong about this workflow.**

`architecture` is silent because **it cannot see**: its selftest dies in 5 of 5 runs, behind
`continue-on-error`, so the harness that proves the gate can still fail is itself failing invisibly.
A gate that has lost the ability to red is not a quiet scream, it is a disconnected one — and from the
outside the two look identical, which is exactly why "never-red is fine for a tripwire" must never be
applied without checking that the tripwire still works. Filed as `task-6891e8f620c1bdea`.

**The general rule survives; the instance does not.** The test that separates them is not the red rate,
it is whether the gate's own selftest passes. Apply that to the other seven tripwires before trusting
their silence.

`reland-check` (2,188 runs) and `architecture` (1,402 runs) are both never-red in 14 days, not
required, and carry no written rationale — they are the two strongest RETIRE-OR-MOVE candidates once
`architecture` can see again.

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

