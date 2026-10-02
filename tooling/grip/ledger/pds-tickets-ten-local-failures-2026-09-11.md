# The ten undiagnosed local failures — diagnosed (2026-09-11)

Task: `pds-bl-tickets-ten-undiagnosed-local-failures`.

**Verdict up front: none of the ten is a product defect.** Eight are one environment
fault (an amended-in-place migration, PDS-D311), one is shared-database residue in
`oban_jobs`, and one does not reproduce in any of six constructed conditions. Both
reproducible causes are already repaired on `main`.

**And the row was stale in a way that matters:** for six of the eight, the diagnosis was
already IN THE TREE when this row was worked — `api/test/barkpark/content/revision_bind_trigger_freshness_test.exs`
(`c7b785c96`, PR #13104, 2026-08-23) names `QueryResolveTasks, ContentPubsubWorkspaceLeak, TicketRateLimit,
BulldocsSessionsController, DocumentsRetrieverBoundedPool, ContentWorkspaceWriteScope` in
its moduledoc and ships a tripwire for the cause. A finding written into a test file does
not update the row that asked for it. What is new here is the two that tripwire does NOT
name — `ProjectorWorkerEnqueue` and `PublicPaperScope` — plus an independent
re-derivation at the wave-22 tree itself.

## 0 — Measurement conditions (every figure below carries these)

| | |
|---|---|
| Today's tree | `628b88afe5d1029876b1c948aa14891bb91052a1` (origin/main, 2026-09-11), worktree `api/ten-local-failures-diagnosis` |
| Wave-22 tree | `a103841ccd5544fc72d88cd557dc725807406780` (2026-07-28 07:30 +0200) — the newest main commit at or before the row's `inserted_at` |
| Private partitions | `MIX_TEST_PARTITION=api_w6` (today's tree), `api_w6_w22` (wave-22 tree). Both created fresh this session; `api_w6`'s `oban_jobs` held 0 rows before the first run. |
| Shared DB | unpartitioned `barkpark_test`, which at measurement time held **1284** committed `scheduled` `ProjectorWorker` `oban_jobs` rows and a committed `default`-slugged workspace |
| Host | `CC=/usr/bin/clang`, Elixir 1.19.5 / OTP 28, PostgreSQL 17. Load averages are stamped per run below; they ranged **7.65 – 30.81** across the session. Durations are upper bounds under a live multi-worker campaign. |

## 1 — The provenance, from the source and not from a paraphrase

The ten were never measured on their own. They are the remainder of ONE local full-suite
run in PDS wave 22 (parent row `pds-bl-tickets-local-otp28-divergence`): 53 failures on a
tree byte-identical to origin/main, of which 16 were a shallow-clone `BuildInfo` artifact
and 27 were the Tickets plugin dying on
`(Postgrex.Error) ERROR P0001 (raise_exception) revision snapshot does not exactly match its document`.
The ten were what was left over, and they were never attributed.

Charter **PDS-D311** later refuted the OTP-28 story for the 27 and named the real cause:
`api/priv/repo/migrations/20260719010000_add_cycle_correction_quarantine_promotion.exs`
shipped at `2e0ca88c7` (2026-07-19 02:19) with an exact-equality
`barkpark_bind_document_revision()` predicate, and was **edited in place** at `a0357fff3`
(06:11) and six more times. Migrations never re-run, so a database created inside that
window keeps the early function body forever while `mix ecto.migrations` reports zero
pending — that check reads a `schema_migrations` version row, never the object.

Repaired on main by `bc38d2529` (PR #14844),
`20260901140000_replace_bind_document_revision_trigger_function.exs`, a forward
`CREATE OR REPLACE` of the final body.

## 2 — The discriminating experiments

### E1 — mutation at today's tree: install the pre-amendment body, re-run the ten
Tree `628b88afe`, partition `api_w6`, load **8.50**. `CREATE OR REPLACE` of the
`2e0ca88c7` function body (`md5(prosrc)` `4e268bf5ce750a8c3c3507353fe35478`, vs the
corrected `01e3314a1e7fb8ad9f152c79d89c79da`), then each file alone at `--seed 1001`:

| module | result | P0001 lines |
|---|---|---|
| ContentPubsubWorkspaceLeak | 8 tests, **8 failures** | 8 |
| QueryResolveTasks | 4 tests, **4 failures** | 4 |
| TicketRateLimit | 7 tests, **1 failure** | 1 |
| BulldocsSessionsController | 24 tests, **5 failures** | 5 |
| DocumentsRetrieverBoundedPool | 4 tests, **4 failures** | 4 |
| ContentWorkspaceWriteScope | 9 tests, **9 failures** | 9 |
| PublicPaperScope | 4 tests, 0 failures | 0 |
| ProjectorWorkerEnqueue | 12 tests, 0 failures | 0 |

Every failure's stack ends the same way:

```
** (Postgrex.Error) ERROR P0001 (raise_exception) revision snapshot does not exactly match its document
  (barkpark 0.1.0) lib/barkpark/content/broadcast.ex:554: Barkpark.Content.Broadcast.save_revision/6
  (barkpark 0.1.0) lib/barkpark/content/broadcast.ex:116: Barkpark.Content.Broadcast.tap_broadcast/7
```

The corrected body was restored afterwards; a control re-run of
`content_workspace_write_scope_test.exs` + the freshness tripwire is **10 tests, 0
failures** at load **7.65**.

**This refutes the standing rate-limiter hypothesis for `TicketRateLimit`.** Its one
failure is not a 429 and not a shared bucket: it is
`test .. write over budget → routed 429 ..:151` dying at
`TicketsController.create/2 → Content.Writer.do_create_document/5 → save_revision/6` with
P0001, before the limiter is ever reached. Read the body, not the test name.

### E2 — the wave-22 tree itself, on a virgin partition
Tree `a103841cc`, partition `api_w6_w22` (fresh), load **15.28**, `--seed 1001`, each file
alone: **all eight GREEN** (8 / 4 / 7 / 19 / 4 / 4 / 10 / 9 tests, 0 failures each).

This is the load-bearing negative. The same code that produced the 53 is green on a
database created today, so **none of the ten is a defect in the wave-22 code**. The virgin
partition's trigger `md5(prosrc)` is `01e3314a…` — the corrected body — because a database
migrated after `a0357fff3` gets the fixed text from the amended file. That is precisely why
this stayed undiagnosed for six weeks: every attempt to reproduce it in a fresh tree
destroys the evidence.

### E3 — the wave-22 tree against the SHARED `barkpark_test`
Load **9.41**, `--seed 1001`:

| module | result |
|---|---|
| PublicPaperScope | 4 tests, 0 failures |
| ProjectorWorkerEnqueue | 10 tests, **1 failure** — REPRODUCED |

```
1) test enqueue/2 — uniqueness across types (lvw-t11-followup-dedup) type-list ORDER
   cannot defeat the dedup (Barkpark.EdgeProjector.ProjectorWorkerEnqueueTest)
   code:  assert [job] = all_enqueued(worker: ProjectorWorker)
   right: [%Oban.Job{id: 774524, state: "scheduled", queue: "edge_projector", ...}, ...]
```

The mechanism is `clean-main-red-baseline-2026-09-10.md` §4: the SQL sandbox rolls back
what a test writes, but rows COMMITTED by an earlier non-sandboxed run are ordinary visible
reads inside the transaction, so `all_enqueued/1` returns residue plus the row the test
just inserted and the singleton match fails.

### E4 — PublicPaperScope under the broken trigger, wave-22 tree
Partition `api_w6_w22` with `4e268bf5…` installed: 4 tests, **0 failures**. Neither the
trigger nor the shared DB explains it in isolation.

### E5 — FULL SUITE at the wave-22 tree with the pre-amendment body
Partition `api_w6_w22`, load ~12, `--seed 1001`:
`27 doctests, 12838 tests, 2324 failures (48 excluded)` in **288.5 s**. Among the ten:

```
ContentPubsubWorkspaceLeak 4 | QueryResolveTasks 4 | TicketRateLimit 1 |
BulldocsSessionsController 3 | DocumentsRetrieverBoundedPool 4 |
ContentWorkspaceWriteScope 9 | PublicPaperScope 0 | ProjectorWorkerEnqueue 0
```

**Calibration caveat, stated because it is the honest weakness of E1/E5: 2324 ≫ 53.** The
wave-22 database did not carry the EARLIEST body. PDS-D311 records seven further
amendments to that file; the wave-22 box carried an intermediate one, which reds a much
narrower set. E1 and E5 therefore prove the MECHANISM and the module SET, never the exact
per-module counts, and the counts above should not be quoted against the row's "×3".

### E6 — FULL SUITE at the wave-22 tree against the SHARED `barkpark_test`
The closest reconstruction of the wave-22 run available today (that database's trigger has
since been hand-repaired, per PDS-D311). Load ~12:
`27 doctests, 12838 tests, 47 failures (48 excluded)` in **505.6 s**. Exactly ONE of the
ten appears: `ProjectorWorkerEnqueueTest` ×1. `PublicPaperScopeTest` ×0. The other 46 are
other modules (`Tasks.TtlSweeperTest` 12, `Tenancy.WorkspaceBundleCatalogDevTest` 6,
`Studio.ChatLiveTest` 4, …) and are outside this row.

### E7 — the tripwire fires (both directions, same database)
`api/test/barkpark/content/revision_bind_trigger_freshness_test.exs`, tree `628b88afe`,
partition `api_w6`:

```
corrected body (01e3314a…):  1 test, 0 failures
early body     (4e268bf5…):  1 test, 1 failure
  assert src =~ "left(document.doc_id, 7) = 'drafts.'"
  "Your database predates the final text of migration 20260719010000 … This is NOT an
   OTP/Elixir divergence and NOT your regression."
restored       (6cc608f8…):  1 test, 0 failures
```

The guard is real and it is not vacuous. (`6cc608f8…` is the `20260901140000` text and
`01e3314a…` the `20260719010000` text; PDS-D311 already established the two differ only in
leading whitespace — `diff -w` exits 0 — so the surviving md5 drift is inert.)

## 3 — The ten, with verdicts

| # | Module | Verdict | Discriminating evidence |
|---|---|---|---|
| 1-3 | `ContentPubsubWorkspaceLeakTest` (×3) | **environment** — amended-in-place migration (PDS-D311) | E1: 8/8 red under the early trigger, all P0001 from `save_revision/6`; E2: green at the wave-22 tree on a virgin DB |
| 4 | `QueryResolveTasksTest` | **environment** — same | E1: 4/4 red, 4× P0001; E2 green |
| 5 | `TicketRateLimitTest` | **environment** — same. **NOT the rate limiter** | E1: 1 failure, and its body is P0001 at `TicketsController.create/2`, not a 429; E2 green |
| 6 | `BulldocsSessionsControllerTest` | **environment** — same | E1: 5/24 red, 5× P0001; E2 green |
| 7 | `DocumentsRetrieverBoundedPoolTest` | **environment** — same | E1: 4/4 red, 4× P0001; E2 green |
| 8 | `ContentWorkspaceWriteScopeTest` | **environment** — same | E1: 9/9 red, 9× P0001; E2 green |
| 9 | `ProjectorWorkerEnqueueTest` | **shared-DB drift** — committed `oban_jobs` residue | E3/E6 reproduce it on shared `barkpark_test` (1284 committed rows) and only there; E1 green under the broken trigger, so it is a different cause from 1-8 |
| 10 | `PublicPaperScopeTest` | **UNREPRODUCED** | green in all six conditions: E2 (wave-22 tree, virgin), E3 (wave-22 tree, shared), E4 (wave-22 tree, broken trigger), E5 (wave-22 full suite, broken trigger), E6 (wave-22 full suite, shared), and today's tree on both databases 3× each |

### Both reproducible causes are already repaired on main

- **1-8** — `bc38d2529` (PR #14844), migration `20260901140000`, forward `CREATE OR REPLACE`
  of the final body; plus the tripwire in `revision_bind_trigger_freshness_test.exs` (`c7b785c96`, PR #13104).
- **9** — `d77da4379` (PR #17303) added a `setup` issuing `Barkpark.Repo.delete_all(Oban.Job)`
  INSIDE the per-test sandbox transaction. Confirmed here: today's tree runs
  `projector_worker_enqueue_test.exs` **12 tests, 0 failures against the shared
  `barkpark_test` holding 1284 committed rows**, while the wave-22 tree's version of the same
  file reds ×1 on that same database (E3). Same DB, two file versions, opposite results — the
  fix is the only difference.

### No product-defect rows were filed, and that is the finding

Criterion 2 asks that real product defects be filed. **There are none among the ten.** E2 is
the proof: the exact wave-22 code, on a database created today, is green across all eight
modules. Filing a row for any of them would be filing a row against a database.

For #10 the honest claim is the weaker one: it is unreproduced, not "fixed" and not
"explained". Its wave-22 failure body is not recorded anywhere — the row carries only the
module name — and no condition I could construct reds it. Attributing it to the D311 class
by association with its nine neighbours would be exactly the reasoning-from-a-summary this
packet exists to replace.

## 4 — What was NOT run

- No full suite at **today's** tree. The subtraction baseline
  (`clean-main-red-baseline-2026-09-10.md` §3) already records `30 doctests, 20020 tests, 0
  failures` on a private partition at `3b77af02b`; re-running it would have measured the
  same thing under worse load.
- No CI run. This work is entirely local by design.
- No attempt to reconstruct the exact intermediate trigger body the wave-22 box carried.
  Six candidate amendments exist (`5a7aa8616a`, `223c1264da`, `fbd25ff938`, `d3b7cb1789`,
  `d6c6f94af9`); bisecting them would narrow E5's counts toward 53 but would not change a
  single verdict.
- The `Studio` chat-residue reds named in the 2026-09-10 baseline §2 were visible in E6's 47
  and are deliberately left alone — they belong to that row, not this one.

## 5 — Re-derivation

```bash
# the two trigger bodies
git show 2e0ca88c7:api/priv/repo/migrations/20260719010000_add_cycle_correction_quarantine_promotion.exs
git show origin/main:api/priv/repo/migrations/20260901140000_replace_bind_document_revision_trigger_function.exs

# what YOUR database actually carries (the only question that matters)
psql -tA -d barkpark_test$MIX_TEST_PARTITION \
  -c "select md5(prosrc) from pg_proc where proname='barkpark_bind_document_revision';"
# corrected: 01e3314a1e7fb8ad9f152c79d89c79da (20260719010000) or
#            6cc608f843add3a6b3d57b0c640d8eae (20260901140000) — inert whitespace apart
# EARLY/broken: 4e268bf5ce750a8c3c3507353fe35478

# or just run the tripwire, which says it in English:
cd api && mix test test/barkpark/content/revision_bind_trigger_freshness_test.exs

# the oban residue
psql -tA -d barkpark_test -c "select worker, state, count(*) from oban_jobs group by 1,2"
```

## 6 — The generalisable lesson

**A test that reads an unfiltered shared table, and a database object a migration claims to
have produced, fail the same way: silently, permanently, and invisibly to the instrument that
is supposed to report them.** `mix ecto.migrations` reports version rows, not function
bodies. `all_enqueued/1` reports the queue, not the test's own inserts. In both cases the
green on a fresh CI database is not evidence about a long-lived one, and the fix in both
cases was to make the test ASSERT its precondition rather than inherit it.

The second lesson is about the ledger, not the code: **six of these ten were diagnosed on
2026-08-23 (`c7b785c96`, PR #13104) and the diagnosis was written into a test file's moduledoc.** The row stayed open
and the modules stayed "undiagnosed" for nineteen days because a finding recorded in the tree
does not fire on the row that asked for it. Search the tree for the module names before
measuring — `grep -rl ContentWorkspaceWriteScope api/test/` would have found it in one
command.
