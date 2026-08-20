# dr-w31 VERIFY — DOC_ID_EMPTY as a fifth arm: re-derivation recipes (2026-08-09)

Verifier: `docid-fifth-arm`. Ground: `origin/main` = `aa1267c11d3278e8de45024ad63b3b6b2a0925ea`;
cloud-db-1 read at `2026-08-09 16:07:42+00` (max `inserted_at`), total 32,851 rows.
No repo edits outside this file. Mutations below were made in throwaway detached
worktrees under the scratchpad and reverted; nothing was committed.

NOTE FIRST: the primary checkout is **790 commits behind origin/main**
(`git rev-list --count HEAD..origin/main` → 790), so
`cd cloud && mix test test/barkpark_cloud/deploy_ledger_test.exs` there fails with
*"Paths given to mix test did not match any directory/file"*. Every run below is in a
worktree at `origin/main` (or at the PR head), with `cloud/deps` + `cloud/_build`
copied in from an existing scratchpad worktree.

## R0 — worktree at origin/main with a usable build

```sh
SC=<scratchpad>
git worktree add --detach $SC/w31docid origin/main
cp -R $SC/w60d706/cloud/deps  $SC/w31docid/cloud/deps
cp -R $SC/w60d706/cloud/_build $SC/w31docid/cloud/_build
cd $SC/w31docid/cloud && CC=clang MIX_ENV=test mix test test/barkpark_cloud/deploy_ledger_test.exs
```

Answer 2026-08-09: **77 tests, 0 failures, 3.9 s** (seed 465212). D243's "60 tests"
and D242's "73 tests" are both stale counts; the suite is 77 today.

## R1 — DOC_ID_EMPTY by day, trailing 14 d (the class HAS a pulse, and it is small)

```sql
SELECT date_trunc('day',inserted_at)::date d, count(*) n,
       count(*) FILTER (WHERE failure_reason ~ 'graph [0-9]+') coded
FROM deployments
WHERE status='failed' AND stage='HEALTH'
  AND failure_reason LIKE '%bp-doc-id marker is empty%'
  AND inserted_at >= now() - interval '14 days'
GROUP BY 1 ORDER BY 1 DESC;
```

Answer: 08-09 **1/1**, 08-08 **7/7**, 08-07 **5/5**, 08-06 250/249, 08-05 119/10,
08-04 200/0, 08-03 332/0, 08-02 590/0, 08-01 651/0, 07-31 755/0 … Coverage since the
corpus-status producer landed is effectively 100% (D240's 99.6% holds; the all-time
6.8% remains a lie of window).

## R2 — the LIVE arrival rate, and the volume verdict it forces

```sql
SELECT count(*) n, min(inserted_at)::text, max(inserted_at)::text
FROM deployments WHERE status='failed' AND stage='HEALTH'
  AND failure_reason LIKE '%bp-doc-id marker is empty%'
  AND inserted_at >= timestamp '2026-08-07 00:00:00';
```

Answer: **13 rows** over 2026-08-07 01:30:30 → 2026-08-09 12:57:12; measuring to the
DB's own clock (16:07:42) that is **64.1 h → 0.203 rows/h → 4.87 rows/day**. Reaching
`min_sample = 200` for this class alone therefore needs **≈ 41 days**. A wave-31
AFTER on DOC_ID_EMPTY is an **INSUFFICIENT VOLUME** verdict by arithmetic, not by
bad luck.

## R3 — every failed row in the trailing 72 h (what is actually still firing)

```sql
SELECT inserted_at::text, stage, left(failure_reason,90)
FROM deployments WHERE status='failed' AND inserted_at >= now() - interval '72 hours'
ORDER BY inserted_at DESC;
```

Answer: the trailing-24 h failure set is **three rows**: `HEALTH` doc-id (08-09 12:57),
`BUILD` HTTP-429 `rate_limited` (08-09 11:59), `RETIRE` `deploy process died abnormally`
(08-09 09:41). Trailing 24 h overall: **volume 738 · failed 3 · deferred 485 · live 250**
(failure_rate 0.41%). DOC_ID_EMPTY is not the *only* class with a pulse — `PROCESS_DIED`
(RETIRE) and `BOX_RATE_LIMITED_429` also fired inside 24 h — but it is the class with
the **most** live rows, and it is 1 of 3, so any share over that denominator is vacuous.

## R4 — the graph-coded population moved AGAIN: 265 → 277 → 285

```sql
SELECT (regexp_match(failure_reason,'graph ([0-9]+)'))[1] code, stage,
       count(*) n, count(DISTINCT site_id) sites
FROM deployments WHERE status='failed' AND failure_reason ~ 'graph [0-9]+'
GROUP BY 1,2 ORDER BY 3 DESC;
```

Answer 2026-08-09: `500`/HEALTH **135** (3 sites), `0`/HEALTH **66** (3),
`503`/HEALTH **63** (3), `500`/BUILD **10** (1), `403`/HEALTH **8** (2),
`403`/BUILD **3** (1) — **272 HEALTH + 13 BUILD = 285**. D238's 277 is stale by 8.
Every HEALTH row is template `search-starter`; the BUILD rows are `astro-search-starter`.
D238's two-dialect ruling survives re-measurement; only its number moved.

Cross-check for Arm B: `SELECT (failure_reason ~ 'graph 500: unknown error'), count(*)
FROM deployments WHERE status='failed' AND failure_reason ~ 'graph 500' GROUP BY 1;`
→ **t | 145** — i.e. **all** 145 graph-500 rows carry the opaque `unknown error` body.

## R5 — the naming gauge is STILL blind to DOC_ID_EMPTY (D243 re-proved on today's main)

MUTATION, in `$SC/w31docid/cloud/lib/barkpark_cloud/deploy_ledger.ex`:

```
"DOC_ID_EMPTY" => "the site owner's build produced no content"   # wrong-blame sentence
```
→ `mix test test/barkpark_cloud/deploy_ledger_test.exs` → **77 tests, 0 failures.**

CONTROL, same file, same shape:

```
"BOX_DEPLOY_DISABLED_503" => "the site owner's build produced no content"
```
→ **77 tests, 1 failure** — ASSERTION A, by name:
`feature_not_configured is the ONLY cause of ["BOX_DEPLOY_DISABLED_503"], but no label there names it`.

The blindness is class-scoped and the gauge can lose. D243 holds verbatim.

## R6 — the split as DESIGNED reds nothing (so it would ship uncovered)

MUTATION on origin/main: add `"CONTENT_API_UNAVAILABLE"` to `@classes` + `@labels`, and
put a `Regex.match?(~r/graph [0-9]+/, reason)` arm ABOVE the `bp-doc-id marker is empty`
arm so coded rows LEAVE the class (D240's partition requirement).

```sh
mix test test/barkpark_cloud/deploy_ledger_test.exs \
         test/barkpark_cloud/deploy_ledger_partition_test.exs \
         test/barkpark_cloud/sites_deploy_test.exs
```
→ **154 tests, 0 failures.** Confirms D243's "a code-conditioned split mutation reds
NOTHING today" on today's main at the larger suite size.

## R7 — THE FINDING D238 DOES NOT KNOW: the split is a LIVE OPEN PR, and it REDS

`git grep -c CONTENT_API origin/main -- cloud/` exits 1 (zero hits) — so D238's "never
landed" is true. But the work is **not lost and not merely unmerged**: task
`dr-w15-s2-graph-code-split-and-agency` (open, priority 0, parent `task-fb4fb869490b4213`,
9 of 10 criteria `met:true`) is **PR #10400**, head `9eca36577efb5c91d5b234599cf5b0cc34803f54`,
state **OPEN**, mergeable **CONFLICTING** / `mergeStateStatus DIRTY`, +702/-10 over 2 files,
last updated 2026-08-07T19:35Z. Its checks carry **`Cloud control-plane (test)` FAILURE**
and **`Cloud gate` FAILURE`**.

```sh
git worktree add --detach $SC/w31pr10400 9eca36577efb5c91d5b234599cf5b0cc34803f54
cp -R $SC/w31docid/cloud/deps $SC/w31pr10400/cloud/deps
cp -R $SC/w31docid/cloud/_build $SC/w31pr10400/cloud/_build
cd $SC/w31pr10400/cloud && CC=clang MIX_ENV=test mix test \
  test/barkpark_cloud/deploy_ledger_test.exs \
  test/barkpark_cloud/deploy_ledger_reachability_test.exs
```

Answer, reproduced locally: **87 tests, 4 failures** — identical to CI's four:

1-3) `BarkparkCloud.DeployLedgerReachabilityTest` × 3, all one cause:
```
newly unreachable (a public with NO caller in cloud/lib — give it a caller,
make it private, delete it, or allowlist it WITH A REASON):
  agency/1, agency_map/0
```
4) `DeployLedgerTest` "the map is EXHAUSTIVE over classes/0 ++ not_attempted_classes/0":
```
** (UndefinedFunctionError) function BarkparkCloud.DeployLedger.not_attempted_classes/0
   is undefined or private. Did you mean: * not_attempted?/1
```
`not_attempted_classes/0` exists on **neither** main nor the branch — only the private
attribute `@not_attempted_classes` and `not_attempted?/1` (main :415, branch :225).

So the split is **NOT liftable as written**. It needs three things D238 does not mention:
(a) one line `def not_attempted_classes, do: @not_attempted_classes`;
(b) a REAL caller in `cloud/lib` for `agency/1` — the reachability guard is correctly
refusing a reader-less instrument, and giving it a reader means touching `router.ex`,
which dr-w15-s2's own fence forbade ("Do NOT touch router.ex … those belong to sibling
slices this round"); (c) a rebase.

## R8 — the rebase conflict is confined, and it is D224's shape

```sh
git merge-tree --write-tree --name-only origin/main 9eca36577efb5c91d5b234599cf5b0cc34803f54
```
→ tree `dafaef5afafd0daec22265b5d9480bbe2baac6e1`, conflicted path **`cloud/lib/barkpark_cloud/deploy_ledger.ex` only**;
`cloud/test/barkpark_cloud/deploy_ledger_test.exs` **auto-merges clean**. That is D224
verbatim: the taxonomy conflicts loudly while its own guard file merges silently.

## R9 — the branch DOES carry D243's stage axis (credit where due)

```sh
git show 9eca36577:cloud/test/barkpark_cloud/deploy_ledger_test.exs | sed -n '1183,1200p'
```
→ `@probe_matrix` gains `{:health, :graph}`, `{:build, :graph}`, `{:health, :no_marker}`
with `graph_word/1` and `@no_marker_word`, driven through both real producer dialects.
`git show 9eca36577:cloud/lib/barkpark_cloud/deploy_ledger.ex | grep -n CONTENT_API`
→ four classes `CONTENT_API_500 / _503 / _UNREACHABLE / _403`, labels, `@agency`
(`:box, :box, :box, :ambiguous`), `content_api_class/1` at :730-743, and no
`CONTENT_API_OTHER` catch-all. D243's "the split and the gauge extension are ONE slice"
is already satisfied by this branch.

## R10 — a label the Go fixture already re-worded and the Elixir never did

```sh
git grep -n 'DOC_ID_EMPTY' origin/main -- internal/ cloud/lib
```
→ `internal/cli/cloud_deploy_census_cmd_test.go:43,1285,1319` all carry
`"label": "the cause went unrecorded"` (D112/D240's re-wording), while
`cloud/lib/barkpark_cloud/deploy_ledger.ex:239` still says
`"HEALTH gate: the bp-doc-id marker was empty"`. The Go side is a hand-written JSON
fixture, so nothing reds — the drift is invisible to both suites.
