<!-- doc-tier: agent | canonical-for: ci-pr-path-inventory | budget: 6000tok -->
# The PR-path CI inventory — what a pull request runs, what it costs, and where each of it belongs

**Generated 2026-09-06 from `origin/main` `cf1f6144e`. Every number below is
produced by `scripts/ci-pr-inventory.py`; none is typed by hand.** Regenerate
rather than edit — a hand-renumbered table rots in its own commit, and this
repo is already paying that elsewhere.

```
scripts/ci-pr-inventory.py --selftest                  # prove the derivations offline
scripts/ci-pr-inventory.py --json > rows.json          # measure (~6 min, ~1400 API calls)
scripts/ci-pr-inventory.py --render rows.json          # re-render the table, zero API calls
scripts/ci-pr-inventory.py --unaccounted               # the context census below
```

`--render` recomputes every verdict from the saved measurement, so the venue
rule can be argued with and re-applied without spending the API budget again.

**These verdicts are a RECOMMENDATION. Nothing here has been implemented, and
no trigger, workflow or branch-protection setting was changed by the commit
that added this file. The required set stays at four contexts until the owner
rules otherwise.**

## The rule these verdicts apply

> A PR runs only what **can block it**, **or** finishes **under 60 s**, **or**
> is **path-filtered to paths the PR actually changed**.

The third clause is the 2026-09-06 amendment, and this table is the first to
apply it: a path-filtered advisory arm is legitimate and is **not** verdicted
`move-to-push` merely for being advisory. Without it, 38 narrow gates that
cost a PR nothing would have read `move-to-push`.

But a `paths:` key is not the same thing as being filtered, so the clause is
tested **empirically**, by fire rate over the 20 most recently merged PR heads,
not by the presence of the key. `doc-gates.yml` declares `paths:` whose globs
are `**/*.md`, `**/*.ex`, `**/*.go`, `**/*.ts`, `**/*.tsx` and
`.github/workflows/**` — it fires on 20 of 20. The cut is drawn at half the
sampled heads (`FILTER_EFFECTIVE_MAX = 0.5` in the script); every row prints
its measured fire rate, so a reader who wants the line elsewhere can move it
and re-render.

Where a mover goes is mechanical too: **`move-to-push`** if the workflow
already has a push-to-main arm (the move is a trigger edit and the main-red
owner already exists); **`move-to-nightly`** if it has none, because moving it
to push would invent a run that has never existed on a tree nobody watches.

## Headline

| | |
|---|---|
| workflow files on `cf1f6144e` | 63 |
| declare `on: pull_request` | **46** |
| actually started a run on ≥1 of the last 20 merged PR heads | **20** |
| fire on **every** one of those 20 heads | **12** |
| workflows starting per PR head | 13–16 |
| check runs per PR head | 50–104 (median 81) |
| **required** (holds a job named in `.github/required-checks.json`) | **4** |
| **feeds-required** at workflow granularity | **0** — see below |
| **advisory** | **42** |
| distinct check-run names rendered on those 20 heads | 96 |
| of those, **UNACCOUNTED** (neither required nor excluded) | **68** |
| verdicts | 42 `keep-on-PR` · 3 `move-to-push` · 1 `move-to-nightly` · 0 `delete` |

**No workflow is `feeds-required`, and that is a fact about the topology, not a
gap in the derivation.** `needs:` is workflow-local and no workflow in this
repo is called as a reusable workflow, so a job can only feed a required
context inside its own file. All four required contexts are self-contained
aggregators. The feeding happens at JOB level, inside the four `required`
workflows, and it is where their compute actually lives:

| workflow | required context | jobs feeding it | jobs feeding nothing required |
|---|---|---|---|
| `elixir.yml` | `Elixir gate` | 6 | 0 |
| `console-harness.yml` | `Console gate` | 7 | 1 (`Report main-push failure to a human`) |
| `cloud.yml` | `Cloud gate` | 4 | 1 (`Report main-push failure to a human`) |
| `pr-task-gate.yml` | `PR references an active task` | 0 | 1 (`PR task gate self-test`, deliberately not a `needs:` — a skipped conclusion satisfies a required context, so wiring the harness upstream would let a red harness turn the gate green) |

## The table

Generated 2026-09-06 by `scripts/ci-pr-inventory.py` over a 30-day window (runs created >= 2026-08-07).

| workflow | authority | fires on N/20 PR heads | declares `paths:` | median real compute (PR) | p90 | main red rate, 30d | main red rate, last 100 | main runs w/ no executed job | verdict | ground |
|---|---|---|---|---|---|---|---|---|---|---|
| `console-harness.yml` | required | 20 | no | 336.0 s (n=12/12) | 711.0 s | 7% (91/1372) | 0% (0/100) | 0/12 | **keep-on-PR** | required: it can block the merge |
| `cloud.yml` | required | 20 | no | 292.0 s (n=12/12) | 311.0 s | 2% (22/1399) | 0% (0/100) | 0/12 | **keep-on-PR** | required: it can block the merge |
| `elixir.yml` | required | 20 | no | 62.5 s (n=12/12) | 1180.0 s | 7% (79/1123) | 6% (6/100) | 0/12 | **keep-on-PR** | required: it can block the merge |
| `pr-task-gate.yml` | required | 20 | no | 48.0 s (n=11/12) | 57.0 s | no main arm | — | 0/0 | **keep-on-PR** | required: it can block the merge |
| `pr-meta.yml` | advisory | 20 | no | 582.5 s (n=12/12) | 619.0 s | 30% (184/609) | 33% (33/100) | 0/12 | **move-to-push** | advisory, 582.5s of real compute that cannot block the merge; it already runs on push to main, so this is a trigger edit |
| `deploy-harnesses.yml` | advisory | 1 | yes | 240.0 s (n=12/12) | 294.0 s | 0% (0/6) | 0% (0/6) | 0/6 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 5% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `compose-smoke.yml` | advisory | 20 | no | 231.5 s (n=12/12) | 245.0 s | 28% (345/1249) | 14% (12/83) | 6/12 | **move-to-push** | advisory, 231.5s of real compute that cannot block the merge; it already runs on push to main, so this is a trigger edit |
| `ci.yml` | advisory | 0 | yes | 221.0 s (n=11/12) | 235.0 s | 4% (2/54) | 4% (2/54) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `js-tests.yml` | advisory | 0 | yes | 217.0 s (n=12/12) | 236.0 s | 14% (14/99) | 11% (10/91) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `create-quickstart-smoke.yml` | advisory | 0 | yes | 176.0 s (n=12/12) | 198.0 s | 0% (0/18) | 0% (0/18) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `connectors.yml` | advisory | 0 | yes | 174.0 s (n=11/12) | 185.0 s | 0% (0/11) | 0% (0/11) | 0/11 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `architecture.yml` | advisory | 12 | yes | 171.0 s (n=12/12) | 180.0 s | no main arm | — | 0/0 | **move-to-nightly** | its `paths:` filter is NOT narrowing — it fires on 60% of sampled PR heads; advisory, 171.0s of real compute that cannot block the merge; it has NO push-to-main arm, so there is no main venue to move to |
| `search-starter-smoke.yml` | advisory | 0 | yes | 140.0 s (n=11/12) | 151.0 s | 0% (0/25) | 0% (0/25) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `doc-gates.yml` | advisory | 20 | yes | 130.0 s (n=12/12) | 140.0 s | 42% (661/1565) | 97% (97/100) | 0/12 | **move-to-push** | its `paths:` filter is NOT narrowing — it fires on 100% of sampled PR heads; advisory, 130.0s of real compute that cannot block the merge; it already runs on push to main, so this is a trigger edit |
| `studio-journey-smoke.yml` | advisory | 0 | yes | 121.0 s (n=2/2) | 121.0 s | 0% (0/1) | 0% (0/1) | 0/1 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `mobile.yml` | advisory | 0 | yes | 83.5 s (n=12/12) | 87.0 s | 0% (0/52) | 0% (0/52) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `typedoc.yml` | advisory | 0 | yes | 64.0 s (n=12/12) | 68.0 s | 0% (0/107) | 0% (0/100) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `paper-editor.yml` | advisory | 0 | yes | 62.0 s (n=12/12) | 65.0 s | 5% (2/38) | 5% (2/38) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `search-template-gates.yml` | advisory | 1 | yes | 62.0 s (n=12/12) | 69.0 s | 33% (60/181) | 0% (0/90) | 1/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 5% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `stale-verdict-watch.yml` | advisory | 0 | yes | 55.0 s (n=12/12) | 58.0 s | 66% (1022/1545) | 13% (13/100) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `reland-check.yml` | advisory | 20 | no | 54.5 s (n=12/12) | 72.0 s | no main arm | — | 0/0 | **keep-on-PR** | advisory, but real compute 54.5s is under the 60s floor |
| `go-format.yml` | advisory | 7 | yes | 54.0 s (n=12/12) | 59.0 s | 19% (43/229) | 26% (25/98) | 1/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 35% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `required-checks-drift.yml` | advisory | 20 | no | 53.0 s (n=12/12) | 59.0 s | 17% (252/1454) | 0% (0/90) | 0/12 | **keep-on-PR** | advisory, but real compute 53.0s is under the 60s floor |
| `security.yml` | advisory | 20 | no | 42.5 s (n=12/12) | 304.0 s | 5% (67/1360) | 0% (0/100) | 0/12 | **keep-on-PR** | advisory, but real compute 42.5s is under the 60s floor |
| `hundesteder.yml` | advisory | 0 | yes | 39.0 s (n=11/12) | 47.0 s | 0% (0/4) | 0% (0/4) | 0/4 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `shell-harnesses.yml` | advisory | 8 | yes | 39.0 s (n=12/12) | 141.0 s | 49% (201/412) | 50% (48/96) | 1/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 40% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `research-coverage-suite.yml` | advisory | 0 | yes | 35.0 s (n=7/8) | 38.0 s | 29% (2/7) | 29% (2/7) | 0/7 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `vendored-assets.yml` | advisory | 0 | yes | 34.5 s (n=6/6) | 39.0 s | 50% (2/4) | 50% (2/4) | 0/4 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `go-tests.yml` | advisory | 20 | no | 33.0 s (n=12/12) | 264.0 s | 11% (35/324) | 11% (10/90) | 1/12 | **keep-on-PR** | advisory, but real compute 33.0s is under the 60s floor |
| `web-fork-drift.yml` | advisory | 0 | yes | 33.0 s (n=12/12) | 36.0 s | 9% (1/11) | 9% (1/11) | 0/11 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `weekly-changelog.yml` | advisory | 0 | yes | 33.0 s (n=5/5) | 41.0 s | no main arm | — | 0/0 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `pdrender-wasm.yml` | advisory | 0 | yes | 30.0 s (n=6/12) | 32.0 s | 0% (0/20) | 0% (0/20) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `astro-search-finder-test.yml` | advisory | 0 | yes | 29.0 s (n=12/12) | 40.0 s | 0% (0/11) | 0% (0/11) | 0/11 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `chronicle-paper.yml` | advisory | 0 | yes | 28.0 s (n=12/12) | 36.0 s | no main arm | — | 0/0 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `crown-reconcile.yml` | advisory | 3 | yes | 24.5 s (n=12/12) | 27.0 s | 60% (897/1488) | 98% (98/100) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 15% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `windows-smoke.yml` | advisory | 0 | yes | 23.0 s (n=3/3) | 24.0 s | 0% (0/2) | 0% (0/2) | 0/2 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `sdk-tests.yml` | advisory | 0 | yes | 18.0 s (n=11/11) | 25.0 s | 0% (0/4) | 0% (0/4) | 0/4 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `plugin-node.yml` | advisory | 0 | yes | 17.0 s (n=2/5) | 18.0 s | 0% (0/2) | 0% (0/2) | 0/2 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `sheet-grid-js.yml` | advisory | 0 | yes | 17.0 s (n=12/12) | 20.0 s | 0% (0/35) | 0% (0/35) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `breakglass-watch.yml` | advisory | 0 | yes | 16.5 s (n=4/4) | 20.0 s | 0% (0/1776) | 0% (0/100) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `cron-overdue-probe.yml` | advisory | 0 | yes | 14.5 s (n=6/6) | 17.0 s | 61% (273/444) | 18% (18/100) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `studio-instrument-selftests.yml` | advisory | 1 | yes | 14.0 s (n=5/5) | 16.0 s | 0% (0/5) | 0% (0/5) | 0/5 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 5% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `task-lease-renew.yml` | advisory | 20 | no | 13.5 s (n=12/12) | 15.0 s | 0% (0/486) | 0% (0/99) | 0/12 | **keep-on-PR** | advisory, but real compute 13.5s is under the 60s floor |
| `astro-finder-drift.yml` | advisory | 0 | yes | 12.0 s (n=11/12) | 13.0 s | 0% (0/19) | 0% (0/19) | 0/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `main-gate-watch.yml` | advisory | 1 | yes | 12.0 s (n=11/11) | 14.0 s | 100% (11/11) | 100% (11/11) | 1/12 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 5% of sampled PR heads): it costs nothing on a PR that misses its paths |
| `bp-graph-drift.yml` | advisory | 0 | yes | 11.0 s (n=6/6) | 11.0 s | 20% (1/5) | 20% (1/5) | 0/5 | **keep-on-PR** | advisory but genuinely PATH-FILTERED (fires on 0% of sampled PR heads): it costs nothing on a PR that misses its paths |

## How each column is measured, and the trap it exists to avoid

**`authority`** — READ, never typed. The required set comes from
`.github/required-checks.json` → `.protection.required_status_checks.checks[].context`
(today: `Cloud gate`, `Console gate`, `Elixir gate`, `PR references an active
task`). `feeds-required` is the transitive `needs:` closure of a job carrying
one of those names.

**`fires on N/20 PR heads`** — `gh pr list --state merged --limit 20`, then
`/actions/runs?head_sha=…&event=pull_request` per head. **This is the column
that separates a declaration from a firing.** The row's own filing says "46 of
59 workflows fire on pull_request"; that counted DECLARATIONS. 46 declare, 20
ever start, 12 always start.

**`median real compute (PR)` / `p90`** — sum of wall-seconds over jobs that
**executed at least one step** (a step concluding `success` or `failure`),
median over the 12 most recent completed PR runs in the window. A job cancelled
*after* running steps DOES count — it burned a runner. One cancelled before its
first step does NOT, and neither does a path-skipped job: both report a
duration and neither did work. The prior recount that found "63% of measured
elixir job-minutes were cancelled runs that never executed a step" is exactly
this trap, and this column is built to not step in it.

**`main red rate, 30d`** — `total_count` from `/actions/workflows/<f>/runs`
with `status=failure` over `status=failure + status=success`. **Cancelled runs
are excluded from the denominator**, not counted green: on a fleet that cancels
superseded runs constantly, folding them in dilutes every rate (doc-gates: 637
cancelled of 2201 completed).

**`main red rate, last 100`** — the recency split, and it is not decoration.
`doc-gates.yml` reads 42% over 30 days and **97% over its last 100 main runs**.
Both are true; only the second one tells you the gate is dead. A 30-day rate
averages across a regime change and will call a workflow that went permanently
red last week healthy.

**`main runs w/ no executed job`** — because **a skipped job reports success**.
A red rate over conclusions alone calls a workflow healthy when it merely never
ran. `compose-smoke.yml` reads 6/12 here: six of its twelve sampled main runs
were cancelled with zero jobs started.

**Counts are censuses, not samples.** `gh run list` and a single `created=`
page set both cap at 1000 items, which is what makes a *paged* 30-day census a
floor. This script never pages a census: it reads `total_count` off a
one-item page, which that ceiling does not bound. Only the **job sample**
(12 runs/venue) and the **recency page** (≤100 runs) are samples, and each row
prints its own n.

## What the row's own prior numbers got wrong, re-derived

| filed claim | measured 2026-09-06 | what went wrong |
|---|---|---|
| "one PR push triggers 55 check runs from **46 workflows**" | 50–104 check runs (median 81) from **13–16 workflows** | 46 is the count of workflows that *declare* `on: pull_request`. Counting declarations overstates the real fan-out ~3x. |
| "**63%** of measured elixir job-minutes were cancelled runs that never executed a step" | **Directionally right, and it understates the effect.** `elixir.yml`'s median real compute on a PR is **62.5 s**, p90 **1180 s** | On 4 of 6 read runs the entire matrix — `Test`, `Prod compile gate`, `Validation perf bench`, `Format` — is SKIPPED; only `Dispatch`, `Elixir path-escape ratchet` and the `Elixir gate` aggregator execute. `elixir.yml` is not the median PR's cost centre. Its *tail* is. |
| "`Test` is 48% of real compute" | Not re-derivable as stated | On the median PR, `Test` runs zero seconds. The figure holds only over the runs where the dispatcher lets the matrix fire. |
| "doc-gates red **157:1** on main" | **97 of the last 100** main runs red (30-day: 661/1565 = 42%) | The ratio was a *recent-window* figure quoted against a 30-day frame. Both are real; the table now carries both columns so the two can never be confused again. |
| "4 contexts are required" | **Confirmed, read not typed** | — |

**One number the filing did not have, and it is the largest movable cost on the
PR path.** `pr-meta.yml` is advisory, fires on 20 of 20 heads, and costs a
median of **582 s**. Reading a run's steps: **573 s of that 615 s is a single
step**, `Run filebase critic on the PR head and the base tip`, which carries
`continue-on-error: true # advisory — report, never block` in its own YAML. The
other fifteen gates in that job total ~35 s. So the table's workflow-level
`move-to-push` is too blunt for this one row: the honest shape is to **split
the job** — keep the ~35 s of fast gates on the PR (they pass the under-60 s
clause on their own) and move the 573 s critic to push or nightly.

That reading is also why this document's own generator selftest is wired into
`pr-meta.yml` and nowhere else: it is a ~1 s offline harness, it belongs with
the fifteen gates that stay, and a harness nobody executes reads as coverage
and is silence. The 582 s median above was measured before that step existed;
it does not move it.

## Contexts nobody has classified

`--unaccounted` diffs the check-run names a real PR head renders against
`required ∪ exclusions`. Over the 20 most recently merged PRs:

- **96** distinct names rendered · **4** required · **24** carry an exclusion row
  · **68 UNACCOUNTED** — neither required nor excluded, so no committed
  artifact says whether their red should ever matter.

This is a known blind spot rather than an oversight:
`required-checks.json`'s own `_readme` concedes *"EXCLUSIONS ARE WHAT THE
SAMPLE SAW, never a complete census"*, and its generator samples main **push**
heads, which render no pull_request-only name at all.

The census runs the other way too, and found live rot. **Four ledger rows match
nothing a real PR head renders:**

| ledger row | why it matches nothing |
|---|---|
| `Test (Elixir 1.18.1 / OTP 27.0)` | the matrix now renders `Test (Elixir 1.18.4 / OTP 27.0)` |
| `Prod compile gate (Elixir 1.18.1 / OTP 27.0)` | same version drift |
| `Format (mix format --check-formatted, advisory) (27.0, 1.18.1)` | renamed *and* re-versioned: renders as `Format (mix format --check-formatted, diff-scoped) (27.0, 1.19.5)` |
| `Break-glass watch` | genuinely paths-filtered; absence here is expected, not rot |

A matrix job's check-run name carries its *interpolated* version, so an
exclusion pinned to one Elixir version silently stops governing the job it was
written for the moment the matrix moves. Three rows are in that state today.
Filing and fixing them is out of this document's scope; recording them is not.

## What was NOT measured

- **The window is 30 days by census, but the job sample is 12 runs per venue
  and the recency page is ≤100 runs.** Every row prints its own n. Where a
  workflow ran fewer than 12 times, the median is over what exists — read the
  `n=` in the compute column before quoting it.
- **The fan-out and context censuses are over "the 20 most recently merged PRs
  *at run time*", which moves.** Two runs 40 minutes apart returned 100 and 96
  distinct names as newer merges rotated in. Treat 68 unaccounted as the shape
  of the finding, not a pinned integer.
- **No before/after.** Criteria 1–4 of the parent row need multi-day
  measurement across an actual change; this document is the baseline they will
  be measured against, and nothing else.
- **Per-job venue verdicts.** The table verdicts whole workflows because that
  is what the criterion asks for. `pr-meta.yml` above shows why the right unit
  is sometimes the job, and `elixir.yml` shows the same from the other side: a
  `keep-on-PR` workflow can still carry an advisory job (`Format`, which is
  `continue-on-error`) whose seat nobody has argued for.
- **Cost in currency.** Everything here is wall-seconds of executed jobs. No
  runner pricing, no concurrency-queue wait, no developer wait time.
- **Whether a red is CORRECT.** A 97%-red workflow may be reporting a real
  defect. The last main `doc-gates` red was read: its only failing step is
  `Decide (main-red breaker — inherited reds are neutral, own reds fail)`, i.e.
  the breaker's own verdict, not a doc-budget overflow. No other red in this
  table was read to the step level, so no claim is made about what any of them
  means.
