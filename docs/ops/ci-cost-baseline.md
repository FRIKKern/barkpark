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

## The two findings that should drive the work

**1. 36.5% of sampled jobs executed nothing** — 142 of 389. They were cancelled while still
queued, with an empty `steps` array. They cost no compute and produced no signal; they are pure
waste, and on 2026-09-02 they were 71 of 131 jobs.

**2. Queue dwarfs compute, and the gap is widening, not closing.** On 2026-09-02 the sample shows
**651 queue minutes against 51 compute minutes** — roughly 13 to 1. Cutting which checks run
attacks the 51. The fleet-versus-ceiling problem owns the 651. A diet that halves compute and
leaves the queue untouched will not visibly move merge throughput.

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
