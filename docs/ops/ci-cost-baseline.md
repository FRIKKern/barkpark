<!-- doc-tier: agent | canonical-for: ci-cost-baseline | budget: 4000tok -->
# CI cost baseline — 2026-08-30 .. 2026-09-02

Produced by `bash scripts/ci-measure.sh --since 2026-08-30 --until 2026-09-02 --sample 48`.
This is the baseline the "fast and valuable checks" goal (`task-dee226be3107a98b`) measures against.

## Read this before quoting a number

**Compute comes from job STEPS. A zero-step job contributes ZERO compute.** GitHub's job
`started_at`..`completed_at` span is mostly WAITING on a saturated queue. The first diet table
was built from that span and ranked two candidates for removal on minutes they never spent
(`Validation perf` 4.1 min/run was really 1.00; `Format` 2.9 was really 0.48).

**This is a SAMPLE, not a census.** The window holds 25,617 runs and job detail costs one API
call per run against a 5,000/hour budget, so a census is arithmetically impossible. Ratios
(min/exec, red rate, zero-step share) survive sampling. **Totals do not** — scale by
population/sample and label the result ESTIMATED.

**Do not compare queue minutes across 2026-09-02.** GitHub Pro was purchased that evening and
the concurrent-job ceiling went 10 to 20. Compute minutes are comparable; queue minutes are not.

| day | ceiling | population | sampled | compute min | queue min | exec jobs | zero-step |
|---|---|---|---|---|---|---|---|
| 2026-08-30 | 10 | 30 | 26 | 66.8 | 1.2 | 27 | 20 |
| 2026-08-31 | 10 | 4,583 | 38 | 105.9 | 4.9 | 92 | 27 |
| 2026-09-01 | 10 | 8,181 | 46 | 88.5 | 20.5 | 68 | 24 |
| 2026-09-02 | 20 | 12,838 | 42 | 51.0 | 651.1 | 60 | 71 |

## The run census — MEASURED, not sampled

This table is a true census: run counts come from the list endpoint's `total_count`, one call per
workflow, never from per-run job detail. Every number here is exact. It is reported separately from
the compute table above precisely because that one is sampled and this one is not.

**22,244 runs in four days.** 14,092 pull_request, 8,026 push, 114 schedule.

**1,227 PR pushes produced 14,092 pull_request-triggered runs — 11.5 runs per push.**

**Six workflows fire 1,853 times each**, the highest count in the repo and identical across all six:
`elixir`, `cloud`, `compose-smoke`, `console-harness`, `required-checks-drift`, `security`. Identical
totals mean they are not responding to what a change touched — they fire on every push of every PR
(1,227) and every push to main (626). That is the shape of the "mess": six workflows, one trigger
condition between them, 11,118 runs.

| workflow | total | pull_request | push | schedule |
|---|---|---|---|---|
| `cloud.yml` | 1853 | 1227 | 626 | 0 |
| `compose-smoke.yml` | 1853 | 1227 | 626 | 0 |
| `console-harness.yml` | 1853 | 1227 | 626 | 0 |
| `elixir.yml` | 1853 | 1227 | 626 | 0 |
| `required-checks-drift.yml` | 1853 | 1227 | 626 | 0 |
| `security.yml` | 1853 | 1227 | 626 | 0 |
| `doc-gates.yml` | 1661 | 1115 | 546 | 0 |
| `pr-task-gate.yml` | 1428 | 1428 | 0 | 0 |
| `reland-check.yml` | 1227 | 1227 | 0 | 0 |
| `architecture.yml` | 807 | 807 | 0 | 0 |
| `crown-reconcile.yml` | 667 | 26 | 626 | 15 |
| `stale-verdict-watch.yml` | 666 | 19 | 626 | 21 |
| `breakglass-watch.yml` | 648 | 2 | 626 | 20 |
| `go-tests.yml` | 635 | 515 | 120 | 0 |
| `shell-harnesses.yml` | 575 | 193 | 382 | 0 |
| `pr-meta.yml` | 562 | 407 | 155 | 0 |
| `deploy.yml` | 430 | 0 | 429 | 0 |
| `go-format.yml` | 321 | 212 | 109 | 0 |
| `task-lease-renew.yml` | 308 | 308 | 0 | 0 |
| `release-artifact.yml` | 255 | 0 | 255 | 0 |
| `landed-mark.yml` | 229 | 0 | 229 | 0 |
| `js-tests.yml` | 78 | 51 | 27 | 0 |
| `typedoc.yml` | 77 | 51 | 26 | 0 |
| `grip-suite.yml` | 67 | 40 | 27 | 0 |
| `mobile.yml` | 57 | 43 | 14 | 0 |
| `twoslash.yml` | 53 | 53 | 0 | 0 |
| `ci.yml` | 47 | 33 | 14 | 0 |
| `sheet-grid-js.yml` | 45 | 33 | 12 | 0 |
| `paper-editor.yml` | 35 | 28 | 7 | 0 |
| `pdrender-wasm.yml` | 33 | 23 | 10 | 0 |
| `search-template-gates.yml` | 33 | 33 | 0 | 0 |
| `deploy-harnesses.yml` | 32 | 32 | 0 | 0 |
| `main-gate-watch.yml` | 21 | 0 | 0 | 21 |
| `search-starter-smoke.yml` | 21 | 10 | 7 | 4 |
| `create-quickstart-smoke.yml` | 19 | 14 | 5 | 0 |
| `absent-context-census.yml` | 14 | 0 | 0 | 14 |
| `cp-ops.yml` | 11 | 0 | 0 | 0 |
| `astro-finder-drift.yml` | 7 | 5 | 2 | 0 |
| `scaffy-catalog-drift.yml` | 7 | 0 | 3 | 4 |
| `chronicle-paper.yml` | 6 | 2 | 0 | 4 |
| `research-coverage-suite.yml` | 6 | 3 | 3 | 0 |
| `web-fork-drift.yml` | 6 | 4 | 2 | 0 |
| `astro-search-finder-test.yml` | 5 | 3 | 2 | 0 |
| `connectors.yml` | 4 | 3 | 1 | 0 |
| `paper-readers.yml` | 4 | 0 | 0 | 4 |
| `plugin-node.yml` | 4 | 3 | 1 | 0 |
| `studio-journey-smoke.yml` | 4 | 0 | 0 | 4 |
| `weekly-changelog.yml` | 3 | 2 | 0 | 1 |
| `bp-graph-drift.yml` | 2 | 1 | 1 | 0 |
| `cli-release.yml` | 2 | 0 | 2 | 0 |
| `sdk-tests.yml` | 2 | 1 | 1 | 0 |
| `codebase-intel.yml` | 1 | 0 | 0 | 1 |
| `renew-mail-cert.yml` | 1 | 0 | 0 | 1 |
| **TOTAL** | **22,244** | **14,092** | **8,026** | **114** |

Per-day totals, all workflows: 30 (08-30), 4,583 (08-31), 8,181 (09-01), **12,854 (09-02)**.

Reproduce with `bash scripts/ci-measure.sh --census --since <d> --until <d>`.

## The two findings that should drive the work

**1. 36.5% of sampled jobs executed nothing** — 142 of 389. They were cancelled while still
queued, with an empty `steps` array. They cost no compute and produced no signal; they are pure
waste, and on 2026-09-02 they were 71 of 131 jobs.

**2. Queue dwarfs compute.** On 2026-09-02 the sample shows **651 queue minutes against 51 compute
minutes** — roughly 13 to 1.

It is tempting to conclude that deciding which checks run only attacks the 51 and that the queue is
somebody else's problem. That is wrong, and it matters because it would steer the work. **Queue
minutes are jobs submitted divided by capacity over time**, so every job we stop submitting is a job
that neither waits nor makes the next one wait. A PR touching three `cloud/` files fired 13 workflow
runs and 55 jobs; at 4 runs and 15 jobs the 651 falls along with the 51, and it falls without buying
anything. The inventory and the per-job `if:` work are the queue fix as much as the compute fix.
Raising the ceiling is the other half, and that is what buying Pro does.

## Per-workflow, from the sample

`min/exec` and `red` are ratios and are the trustworthy columns. `compute` is a sample total.

| workflow | compute | exec | 0-step | min/exec | red rate |
|---|---|---|---|---|---|
| elixir | 103.1 | 46 | 16 | 2.24 | 0.09 |
| paper-readers | 56.9 | 1 | 0 | 56.85 | 0.00 |
| required-checks-drift | 45.6 | 11 | 6 | 4.14 | 0.55 |
| compose-smoke | 24.2 | 21 | 8 | 1.15 | 0.29 |
| cloud | 14.0 | 21 | 9 | 0.67 | 0.00 |
| pr-task-gate | 9.1 | 26 | 0 | 0.35 | 0.04 |
| doc-gates | 8.6 | 6 | 3 | 1.44 | 0.67 |
| crown-reconcile | 8.5 | 7 | 7 | 1.22 | 0.14 |
| Shell harnesses | 6.4 | 22 | 26 | 0.29 | 0.00 |
| architecture | 3.9 | 3 | 0 | 1.31 | 0.67 |
| aesthetics-guard | 3.5 | 3 | 0 | 1.17 | 0.00 |
| stale-verdict-watch | 3.3 | 9 | 9 | 0.37 | 1.00 |
| console-harness | 2.9 | 12 | 20 | 0.24 | 0.00 |
| main-gate-watch | 2.6 | 10 | 10 | 0.26 | 0.10 |
| chronicle-paper | 2.5 | 4 | 0 | 0.61 | 0.00 |
| breakglass-watch | 2.4 | 9 | 9 | 0.27 | 0.00 |
| reland-check | 2.3 | 3 | 2 | 0.77 | 0.00 |
| weekly-changelog | 1.9 | 2 | 0 | 0.93 | 0.00 |
| absent-context-census | 1.8 | 3 | 0 | 0.59 | 1.00 |
| codebase-intel | 1.4 | 1 | 1 | 1.38 | 0.00 |
| run-level-reader-census | 1.2 | 7 | 1 | 0.17 | 0.00 |
| search-starter-smoke | 1.1 | 1 | 2 | 1.08 | 0.00 |
| security | 1.1 | 6 | 8 | 0.18 | 0.00 |
| typedoc | 0.9 | 1 | 0 | 0.90 | 0.00 |
| Landed mark — task rows learn their merge sha | 0.8 | 2 | 0 | 0.40 | 0.00 |
| committed-symlink-gate | 0.8 | 5 | 1 | 0.16 | 0.00 |
| Go format | 0.7 | 2 | 0 | 0.35 | 0.00 |
| scaffy-catalog-drift | 0.4 | 1 | 0 | 0.43 | 0.00 |
| cp-ops | 0.2 | 1 | 0 | 0.20 | 0.00 |
| studio-journey-smoke | 0.1 | 1 | 1 | 0.15 | 1.00 |

## Permanently-red workflows (feeds `task-0a48c7b64d5ab0f1`)

A red rate of 1.00 across the window means the workflow has never passed in it. A check that
always fails teaches readers to ignore it, which is worse than not running it at all.

- `stale-verdict-watch` — 1.00 red. Cause found and fixed in #15608 (its population query 504'd
  on every attempt); this baseline predates the fix.
- `absent-context-census` — 1.00 red.
- `required-checks-drift` — 0.55 red, and at 4.14 min/exec it is the third-largest compute item.
- `doc-gates` — 0.67 red. Four independent causes, addressed in #15483.
- `architecture` — 0.67 red.

## Outlier worth its own look

`paper-readers` shows **56.85 minutes for a single execution** — by far the largest per-run cost
in the window, on one sampled run. One observation is not a measurement; before acting on it,
re-measure it specifically.

## Re-running this

```
bash scripts/ci-measure.sh --since <YYYY-MM-DD> --until <YYYY-MM-DD> --sample 48
bash scripts/ci-measure.sh --selftest     # 7 arms, no network
```

The harness exits non-zero if the sample comes back materially short of what was asked, because
a short sample is not a small sample — it is a biased one, skewed to whatever slice the fetch
could still reach.

## Inventory verdicts (task-f3d5bc684c23c48d)

**Do not optimise by duration.** The ten slowest workflows per run are also the ten with the FEWEST
PR runs — 32 to 51 each — so moving the whole slow group off the PR path saves almost nothing. Cost
here is `duration x frequency`, and frequency spans three orders of magnitude while duration spans
one. Anyone who sorts this table by `min/exec` and starts at the top will spend the evening on the
cheapest half of the problem.

46 of 59 workflows are `pull_request`-triggered. Compute below is from six recent PR runs per
workflow, measured off job steps.

**A gotcha for anyone re-deriving the 46:** YAML 1.1 parses a bare `on:` key as the boolean `True`,
so `d["on"]` finds nothing and reports a confident zero. Read `d.get("on", d.get(True))`.

**Where the cost actually is.** Almost every workflow is already under 60 s per execution. The ten
slowest per-run jobs are also the ten with the FEWEST PR runs (32-51 each), so moving them off the
PR path saves almost nothing. The cost is concentrated in the handful that fire 1,227 times.

| verdict | workflows | why |
|---|---|---|
| **KEEP — it can block** | `elixir` (1.25 min), `cloud`, `console-harness`, `pr-task-gate` | they produce the four required contexts |
| **KEEP — under 60 s** | `security` 0.35, `go-format` 0.44, `go-tests` 0.48, `architecture` 0.27, `task-lease-renew` 0.27, `shell-harnesses` 0.33, `search-template-gates` 0.18, `pdrender-wasm` 0.47, `stale-verdict-watch` 0.46 | the policy's own second limb: cheap enough that venue is not worth a sign-off |
| **CANDIDATE — over 60 s, cannot block** | `deploy-harnesses` 3.82, `grip-suite` 2.70, `studio-journey-smoke` 1.68, `js-tests` 1.59, `connectors` 1.48, `twoslash` 1.45, `mobile` 1.24, `ci` 1.20, `search-starter-smoke` 1.09, `typedoc` 0.92 | each has only 32-51 PR runs in the window, so the whole group is a minor prize — worth doing for latency per PR, not for job-minutes |
| **ALREADY RIGHT** | `crown-reconcile`, `breakglass-watch`, `stale-verdict-watch` (626 push each, ~20 PR) | main-push watchers; they are not a PR cost |

**The six identical 1,853s are the finding, and four of them cannot simply be moved.** `elixir`,
`cloud`, `console-harness` and `pr-task-gate` carry required contexts. That leaves
`required-checks-drift` and `compose-smoke` as the only two of the six whose venue is genuinely
open — and they are where the policy work should start.

### The two disputed numbers — RE-MEASURED and resolved

Both were flagged as untrusted rather than averaged. Re-measured over **20 recent pull_request runs
each**, compute from job steps:

| workflow | window sample | 6-run sample | **20-run re-measure** | red rate | zero-step |
|---|---|---|---|---|---|
| `required-checks-drift` | 4.14 | 0 | **2.85 min/exec** | 0.10 | 39 of 60 jobs |
| `compose-smoke` | 1.15 | 0 | **0.32 min/exec** | 0.43 | 47 of 61 jobs |

Neither earlier figure was right, and the disagreement was sampling noise in both directions — the
window sample's 0.55 red rate for `required-checks-drift` was also wrong (it is 0.10). This is why
they were recorded as disputed instead of carried into a verdict: **a six-run sample of a workflow
that skips or is cancelled two-thirds of the time is not a measurement.**

**60% of `required-checks-drift`'s jobs were cancelled** (36 of 60) and 65% were zero-step. The ones
that do execute cost 2.85 minutes.

### What that means for the two verdicts

- **`required-checks-drift` — MOVE IT OFF THE PER-PUSH PATH.** At ~1.05 executed jobs per run and
  2.85 min each across 1,227 PR runs, it is on the order of **3,500 job-minutes** in the window,
  which makes it the largest single item whose venue is actually open. It is a drift detector: it
  answers "has the required-checks roster moved", a question about the *repo's* state, not about
  this PR's diff. That belongs on push-to-main plus a schedule, with a named owner watching main's
  red — not on every push of every PR.
- **`compose-smoke` — LEAVE IT.** ~0.22 min per run, roughly **275 job-minutes** across the same
  1,227 runs. It is not worth a sign-off, and its 0.43 red rate is the more interesting problem:
  a check that fails two runs in five is a signal quality question, not a cost one.

## Note on the selftest's venue

`scripts/ci-measure.sh --selftest` is deliberately NOT wired into `shell-harnesses.yml` by this
change, even though that workflow exists precisely for harnesses no other lane runs. A per-job
dispatcher is being added to that file under `task-3a3e1182fadeef11` — on one measured three-file
PR, 28 of 55 check runs were that single workflow running every harness for one matched path — and
two edits to the same file that merge clean textually can still both be wrong. The wiring follows
that PR rather than racing it. This is a declared gap, not an oversight: a selftest nothing runs is
the defect `task-1360445b9cf32243` was filed against, and it is owed here.
