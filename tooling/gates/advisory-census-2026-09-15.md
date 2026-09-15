<!-- doc-tier: human -->
# Advisory check-run census — 2026-09-15

> **How many of the ~116 advisory check-runs has anyone acted on in the last month?**
> A check that has never changed a decision is not a safety net — it is queue depth.

Regenerate: `node tooling/gates/advisory-census.mjs --days 30 --heads 30 --merged 40`
Raw run: [`advisory-census-2026-09-15.json`](advisory-census-2026-09-15.json)

**This report is a snapshot. The script is the rule.** Every number below came out of that
command; nothing here was typed from memory, and the JSON beside it is the run that produced it.

---

## Relation to the prior instrument — found late, declared rather than buried

`.github/ci-pr-inventory.md` + `scripts/ci-pr-inventory.py` (PR #16550, 2026-09-06, the same
parent row's criterion 1) already census the PR path. **This is not a replacement and it does not
re-derive what that table already holds.** The overlap and the delta, stated exactly:

| | prior inventory | this census |
|---|---|---|
| Unit of verdict | **workflow** (46 rows) | **check-run name** (185 rows) |
| Red rate measured on | `push` to **main** | **`pull_request`** — the venue the verdict is about |
| Feeds-required | 0 *at workflow granularity*, with the job-level table given by hand | **derived**: the transitive `needs:` closure of each required aggregator, matched through matrix-name rendering — **25 names** |
| Compute | median real compute per workflow, excluding runs that executed no step | wall-clock per check-run name, plus the **executed / skipped** split per head |
| "Acted on" | not attempted | **Layer M**: advisory reds sitting on **merged** heads |
| `continue-on-error` | noted for `Format` in prose | counted per workflow and attached to **every** verdict's `why` |

That document names **"per-job venue verdicts"** in its own *What was NOT measured* section. This
census is that gap, at that granularity, on the PR-event red rate — and it reaches a verdict the
workflow-granular table structurally could not: `reland-check` is one workflow with one job, so the
prior table can see its cost, but only a job-level read of `continue-on-error` turns 0-failures
from a clean record into a **structural impossibility**.

It also **independently corroborates the contested criterion 2** ("check runs per PR push … under
20"). That criterion was contested on 15 merged PRs with the argument that skipped check-runs cost
nothing and job-seconds is the right metric. Measured here over 30 heads: **48.4 of 99.3 check-runs
per head are `skipped`**. Same conclusion, four times the sample, arrived at without reading the
objection first.

---

## Window and method

| | |
|---|---|
| Window | `created>=2026-08-16` … 2026-09-15 (30 days), event `pull_request` |
| Required set | read at run time from `.github/required-checks.json` — `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active task` |
| Layer P (population, **complete**) | per-workflow `pull_request` run / failure / cancellation counts for all 85 workflows |
| Layer B (burst, **complete per workflow**) | every failing run of every failing workflow, bucketed by hour |
| Layer H (heads, **sampled**) | 30 recent PR heads, check-run rollup **paginated to completion** |
| Layer M (merged-past, **sampled**) | 40 PRs merged inside the window, rollups paginated to completion |
| Layer S (static, **complete**) | `on:` triggers, workflow-level `paths:`, `continue-on-error`, and the transitive `needs:` closure of each required aggregator |
| API calls | 1137 |

### Traps this run actually avoided, each with the read that proves it

- **Pagination.** `per_page=100` is *not* enough. Measured on this repo's main head:
  `total_count=121, received=100`. Every rollup in Layers H and M is read until
  `collected === total_count`; a short read returns `ok:false` and the head is **excluded and
  reported**, never counted. Across 70 rollups, 0 were truncated. Observed check-runs per head:
  **69–188**.
- **`total_count` on `/actions/runs` is not a count when unfiltered.** The bare endpoint returns
  40000 flat. Under a filter it is exact, and that is the only form used.
- **`?workflow_id=N` on `/actions/runs` is silently ignored.** The first cut of this census
  printed the identical triple `83828 / 5102 / 14530` against all 85 workflows — the repo-wide
  total wearing 85 names. Scoping lives in the *path*: `/actions/workflows/{id}/runs`. The script
  now **refuses to print** a result where every workflow reports the same run count, and prints the
  control every run: *48 distinct per-workflow run counts; sum(per-workflow)=78822 ≤ repo-wide
  84056*.
- **`continue-on-error: true` makes a failure report `success`.** Layer S counts it and flags the
  name; **113 of 181 advisory names** sit in a workflow that carries it. Their green is not
  evidence — see `reland-check` below, where it is the whole finding.
- **A rerun overwrites a conclusion.** Stated as a limit, not worked around: every failure count
  here is a **floor**.
- **An uninterpolated `${{ … }}` in a rendered name is an empty matrix, not a check.** Those names
  are excluded from every removal verdict.
- **A matrix job's rendered name is not its `name:`.** Matching the load-bearing set literally
  reported the entire Elixir test matrix — the required gate's own upstream — as *not*
  load-bearing. Fixed by matching through the rendering; the load-bearing count moved 18 → **25**.
- **A job name can render from several workflows.** `Report main-push failure to a human` renders
  from **nine**. Ambiguous names take the worst-case failure record and are **forced to
  keep-on-PR** — this census is not entitled to move a name it cannot attribute.

---

## Headline

| | |
|---|---|
| Distinct check-run names on sampled heads | **185** |
| Advisory (cannot block a merge) | **181** |
| Advisory **load-bearing** — transitive `needs` of a required aggregator | **25** ← untouchable |
| Advisory in a workflow with **zero failing PR runs** in 30 days | **16** (13 of which actually ran) |
| Advisory that **never actually ran** — `skipped` on every sampled head | **29** |
| Advisory whose workflow carries `continue-on-error` | **113** ← green is not evidence |

### Cost today, per PR head

| | |
|---|---|
| Check-runs per head, mean / median | **99.3 / 78** |
| …of which **executed** / **skipped** | **50.9 / 48.4** |
| Runner-seconds per head | **~1980** |

Nearly half of the ~120 rows on a head are `skipped`: they render a row and consume no runner and
no queue slot. **The rollup depth and the queue depth are not the same number**, and conflating
them is how a fleet talks itself into a 60% saving that does not exist.

---

## "Acted on" — what was and was not measured

**Measured (runs, reds).** Every name's run count and non-success count, at the granularities above.

**Measured, negatively (Layer M).** Across **40 merged PRs**, **29 advisory reds shipped
uncleared** — 7 distinct names sitting non-success on a head that merged anyway, because they
could. Nobody cleared them and nobody re-ran them green.

| merged PRs carrying this red at merge | name |
|---:|---|
| 10 | `bp CLI release cadence` |
| 6 | `Doc budgets + anchors` |
| 4 | `Required-check spec drift (advisory)` |
| 3 | `Build + test + gates` |
| 3 | `compose-smoke dispatcher covers the census roots` |
| 2 | `reland-check / fleet-run-verdict / paper-reader-audit harnesses` |
| 1 | `shell-harnesses dispatcher partition + fixture matrix` |

`bp CLI release cadence` was red at merge on **1 in 4** of the merged PRs sampled. That is a
demonstration, not an inference: the red shipped.

**NOT measured: human attention.** There is no API for it. The proxy the brief suggested — *did a
red on name N precede a commit touching what N guards* — needs a committed name→guarded-paths map
this repo does not have, and even with one, the reds most likely to have been acted on are exactly
the reds a rerun destroys. `node tooling/gates/advisory-census.mjs --proxy-note` prints the full
argument. **This census measured runs and reds, not human attention.** A name with zero reds has
demonstrably never caught anything; a name with reds *may* have been acted on, and this tool does
not claim to know.

---

## The prior, tested rather than assumed

The brief offered a prior: *several of these are censuses of repo state, not checks on a diff —
`crown-reconcile`, `cli-release-cadence`, `POSIX vacuous-green census`, `pipefail-sigpipe-scan` —
and a census of repo state needs a schedule, not a PR trigger.*

Two instruments were pointed at it. **The prior holds for two of the four, is refuted for one, and
is contradicted by the data for the fourth.**

| workflow | PR runs | failures | rate | workflow-level `paths:` | co-fail share | max PRs red/hr | verdict |
|---|---:|---:|---:|---|---:|---:|---|
| `pipefail-sigpipe-scan.yml` | 1497 | 55 | 3.7% | **none** | 1.10 | 9 | **move-to-schedule** — prior confirmed |
| `cli-release-cadence.yml` | 595 | 50 | 8.4% | **none** | 1.11 | 6 | **move-to-schedule** — prior confirmed, and 10/40 merges shipped its red |
| `posix-vacuous-green-census.yml` | 729 | 94 | **12.9%** | **none** | 1.39 | 8 | **keep-on-PR** — it reds on one PR in eight. Too much signal to put on a schedule; the fix is a `paths:` filter, not a trigger move |
| `crown-reconcile.yml` | 250 | 2 | 0.8% | **yes** | 0.00 | 1 | **keep-on-PR** — already diff-scoped, 250 runs in 30 days. It is not a per-PR burden and never was |

**The burst discriminator was built, run, and came back inconclusive — reported as such.** Layer B
bucketed every failing run by hour to separate "a check on this diff" (isolated reds) from "a
census of repo state" (every open PR reds at once). In *this* repo it does not discriminate: the
census candidates score 1.10–1.39, and unambiguous diff-checks score inside the same band —
`go-tests` 1.45, `elixir` 1.12, `architecture` 1.37. With 15–20 PRs open simultaneously and reds
propagating from main, almost everything correlates. The metric is kept, printed, and **not used as
evidence for any verdict**.

---

## The single largest finding: a check that cannot be red

`reland-check.yml` — `Re-land advisory (already-landed overlap)`

- **5499 `pull_request` runs in 30 days. Zero failures.**
- `reland-check.yml:45` — `continue-on-error: true  # advisory — report, never block`, at **job**
  level. The header says so explicitly: every loud state is a `::warning::`/`::notice::` plus an
  `always()` summary, **never** an `::error::`.
- So the zero is **structural**. It is not a clean record; the check is incapable of producing a
  non-clean one. It cannot fail, therefore it has never caught anything *as a check* — its output
  is a job-summary warning a human must go and read.
- Cost: ~65 s × 5499 runs ≈ **99 runner-hours per month**, on every PR, with no `paths:` filter.
- It also shipped red-at-merge twice under its harness name in the 40-PR merged sample.

This is the shape the brief was looking for, found by measurement rather than by name.

---

## Classification

`delete` was reserved for a name with **nowhere else to go**. **Nothing qualified** — every
zero-signal name turned out to have a schedule arm already, so the honest verdict was
move-to-schedule. Reporting zero deletions is the finding, not a gap.

| verdict | names |
|---|---:|
| `REQUIRED` — never proposed for change | 4 |
| `keep-on-PR` | 156 |
| `move-to-push` | 18 |
| `move-to-schedule` | 7 |
| `delete` | **0** |

`keep-on-PR` splits into three grounds, all machine-derived and carried in the JSON's `why` field:
**load-bearing** (25 — removing one reds or vacuums a required gate), **ambiguous attribution**
(1 — `Report main-push failure to a human`, which renders from nine workflows), and the remaining
130 on **it reds, and it is diff-scoped** or **it reds too often to move** (the `posix-vacuous-green
census` case above).

### `move-to-schedule` (7)

| occ/30 heads | executed | avg s | PR runs | fails | name | ground |
|---:|---:|---:|---:|---:|---|---|
| 30 | 30 | 65 | 5499 | **0** | `Re-land advisory (already-landed overlap)` | 0 failures in 5499 runs; `continue-on-error` at job level makes that structural |
| 29 | 29 | 33 | 1497 | 55 | `pipefail scan — did the scanner's inputs move?` | no `paths:` filter, schedule arm exists, reds on 3.7% |
| 29 | 9 | 20 | 1497 | 55 | `pipefail SIGPIPE scan` | same workflow |
| 29 | 29 | 34 | 595 | 50 | `cadence — did the CLI's shipped surface move?` | no `paths:` filter, schedule arm exists, reds on 8.4% |
| 29 | 9 | 9 | 595 | 50 | `bp CLI release cadence` | same workflow; **red at merge on 10 of 40 merged PRs** |
| 1 | 0 | – | 44 | 0 | `Publish weekly changelog` | 0 failures; `skipped` on every sampled head; schedule arm exists |
| 1 | 0 | – | 45 | 0 | `Break-glass watch` | 0 failures; `skipped` on every sampled head; schedule arm exists |

### `move-to-push` (18)

The three volume rows first — these are the per-PR cost:

| occ/30 heads | executed | avg s | PR runs | fails | rate | name |
|---:|---:|---:|---:|---:|---:|---|
| 60 | 30 | 6 | 1425 | 1 | 0.07% | `Dependabot trailer injector self-test` |
| 60 | 1 | – | 1425 | 1 | 0.07% | `Dependabot PRs carry the standing task trailer` |
| 47 | 47 | 15 | 5585 | 1 | 0.02% | `Keep the claim alive while this PR is open` |
| 47 | 0 | – | 5585 | 1 | 0.02% | `Renew every open PR's claim (20-min sweep)` |
| 30 | 30 | 33 | 1056 | 1 | 0.09% | `Does this diff touch the Astro finder surface?` |
| 30 | 2 | 3 | 1056 | 1 | 0.09% | `Finder island renders (headless chromium)` |

The remaining 12 each appeared **once** across 30 heads — they are already effectively
paths-gated, and their ground is the same: **zero failures over the whole window**. `sdk/ build +
unit tests` (61 runs), `Sheet-grid hook unit harness` (173), `make wasm + node smoke` (138),
`install-cli.ps1 runs on windows-latest (hermetic)` (42), `Studio instrument selftests` (61),
`Render rig (gate.sh)` (65), `Browser-token build guard (both editions)` (73), `Finder seed-shape
contract` (73), `Break-glass harness` (45), `Weekly changelog generator` (44), `Discover plugin
matrix` (62), `No node-capable plugins (skip)` (62).

`Dependabot trailer injector self-test` deserves a specific note: it executes on **every** PR
(30/30 sampled heads) to self-test a trailer injector that only ever applies to Dependabot PRs.
Its failure record over 1425 runs is a single red.

---

## Projected reduction

| | |
|---|---:|
| Check-runs removed per head | **14.5** of 99.3 (**15%**) |
| …of which actually **executed** | **7.6** of 50.9 (**15%**) |
| Runner-seconds removed per head | **213** of ~1980 (**11%**) |

**Said plainly: this would not have prevented this morning's queue.** 15 PRs × 7.6 fewer executed
jobs is ~114 fewer queued runs — real, and the same order as the 104-deep queue — but the four
required gates and their 25 load-bearing upstreams are the bulk of the *runner* cost and none of
them can move. A trigger-hygiene pass is worth doing on its own merits; **runner capacity and a
deploy lane that does not share a queue with PR CI are the actual remedy** for the incident in
`task-dee226be3107a98b`.

---

## What this method cannot see

1. **Human attention.** Only the negative direction (Layer M: a red that shipped). A green at
   merge is not evidence anyone looked.
2. **Reruns overwrite conclusions in place.** Only timestamps survive. Every failure count is a
   **floor**; the tool never overcounts and can undercount by an unknown amount.
3. **Superseded heads.** Layer H and M read each PR's *current* head. Check-runs on force-pushed-
   away heads are unreachable from the pulls API.
4. **Failure attribution is workflow-granular.** Layer P knows `elixir.yml` failed 605 times; it
   does not know which of its jobs. A name inside a failing workflow may itself never have failed.
   Fixing this means a `/runs/{id}/jobs` call per failing run — ~5000 calls — and was not spent.
5. **Job-minutes are wall-clock, not billed minutes.** `started_at → completed_at` on the
   check-run. Queue wait is not in that payload, so **no name here is attributed a share of the
   104-deep queue**.
6. **Layers H and M are samples** (30 heads, 40 merged PRs) drawn from the most recently updated
   PRs — the fleet's own recent activity, not a uniform draw over 30 days. Layers P, B and S are
   complete.
7. **`continue-on-error` at step level is counted but not localised.** The tool flags that a
   workflow carries it; it does not prove *which* assertion is laundered. Only `reland-check` was
   read to source and confirmed.

---

## Scope note

This is a **measurement**. No `on:` block was touched, no workflow file was edited, and no change
to the required four is proposed or implied. The classifications above are recommendations with
their evidence attached, for the gates lead to route.
