# main's own red set — the subtraction baseline (2026-09-10)

A builder cannot tell their red from main's without this. Subtract what is here
BEFORE claiming your branch broke something. Re-derive with the recipes below;
do not trust this file past a few days — CI context names churn.

Task: `spd-clean-main-red-baseline`. Supersedes the August snapshot carried in
that task's description, which is stale in five separate ways (see §5).

## 1 — Which contexts can actually block a merge

Read from `.github/required-checks.json` at
`3b77af02bd6c2888ba2f51d279c9b82de6a6cf8e` (2026-09-10):

```
enforced: True   branch: main   repo: FRIKKern/barkpark
enforce_admins = True
required_status_checks.strict: False
required_status_checks.checks:
  [{"context": "Cloud gate",  "app_id": 15368},
   {"context": "Console gate","app_id": 15368},
   {"context": "Elixir gate", "app_id": 15368},
   {"context": "PR references an active task", "app_id": 15368}]
```

FOUR contexts, not two. Everything else — however loudly its own name says
"blocking" — is **advisory by protection**: it reds its check run and the merge
button stays green. `strict: false` means main does not have to be up to date;
`enforce_admins: true` means the four are not waivable by an admin either.

## 2 — main's red set TODAY, from PER-COMMIT check-runs

The run rollup lies (a `continue-on-error` job that failed still reports the RUN
as success), so this is derived from
`GET /repos/FRIKKern/barkpark/commits/<sha>/check-runs`, newest run per NAME.

**main's head at the time of writing — `3b77af02bd6c2888ba2f51d279c9b82de6a6cf8e`
(2026-09-10 11:24:17 +0200) — is UNKNOWN.** 21 of its 26 check-runs were still
`queued` when read at 09:24Z, four minutes after the push. main takes a commit
every few minutes during a campaign, so a *head* sha essentially never has a
settled set. Do not guess at a queued context; go back to the newest settled one.

**Newest main commit with ZERO non-completed check-runs:
`0aba08d2114b20622e8fc764aa5ed6deb3150b6f` (2026-09-10 10:43:22 +0200)**, 62
distinct names, 67 raw runs. Its red set:

| Context | Verdict | Why it is red |
|---|---|---|
| `Doc budgets + anchors` | advisory-by-protection | the job bundles the literal checks: `go-literal-check: FAILED — inline color literal(s) in CLI/TUI Go source. internal/cli/tasks_stamp_cmd.go:224` — the "literal" is the string `"PR #123 merged to main as <sha>; "`, i.e. `#123` read as a 3-digit CSS hex. A false positive in prose, not a colour bug. |
| `Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)` | advisory-by-protection | `Traversal.FileModule: Directory Traversal in File.rm_rf - Low Confidence — File: lib/barkpark/sites/deploy_runner.ex, Line: 2191, Function: drop_staged_prebuilt:2190` — off the `.sobelow-skips` baseline. |
| `Crown reconcile` | advisory-by-protection | `VERDICT: NOT reconciled — behind=3/73 delivering runs, wrong=0/100 rows`. Three deploys delivered a sha the crown has no row for (`1f1e74f2…`, `fdbae3d1…`, `ad27846e…`). A record gap, not a code defect. |
| `Stale verdict watch` | advisory-by-protection | `UNREACHABLE — the pull-request list could not be read after every attempt` — `HTTP 502` x3 then `HTTP 403 — You have exceeded a secondary rate limit`. Transport, self-clearing. |

**All four required contexts were GREEN on that commit**: `Cloud gate` success,
`Console gate` success, `Elixir gate` success, `PR references an active task`
success. So on 2026-09-10 main is red on four names and mergeable on all four
that matter.

### Stability across five settled main commits

| context | 0aba08d | 600cc7c | c4da1e7 | 85d3e0f | e102278 |
|---|---|---|---|---|---|
| Doc budgets + anchors | RED | RED | RED | RED | RED |
| Sobelow static analysis | RED | RED | RED | RED | RED |
| Crown reconcile | RED | — | — | — | RED |
| Stale verdict watch | RED | RED | — | — | RED |

Two are **persistent** (subtract them always). Two are **intermittent** — if you
see them, they are still main's, not yours.

## 3 — The full Elixir suite on clean, unmodified origin/main is GREEN

The task row's central premise — "THE FULL SUITE ON CLEAN, UNMODIFIED origin/main
IS NOT GREEN: 27 doctests, 13015 tests, 2 failures" — **no longer holds.**

Run 2026-09-10 in a worktree cut from `origin/main` at
`3b77af02bd6c2888ba2f51d279c9b82de6a6cf8e`, under a private partition, output to
a FILE (never piped to `tail` — that pipe is what lost the second failure in
August):

```
$ cd <wt>/api && CC=/usr/bin/clang MIX_TEST_PARTITION=r4w8 MIX_ENV=test \
    mix test > full-suite.log 2>&1; echo EXIT=$?

Finished in 531.9 seconds (77.4s async, 454.4s sync)
30 doctests, 20020 tests, 0 failures (32 excluded)
EXIT=0
```

`grep -cE '^\s+[0-9]+\) test ' full-suite.log` → **0**. There is no failure
block to name, so "identify the second failure" is moot: today there is neither
a first nor a second. The suite also grew from 13015 tests to 20020 since the
August measurement, so the two are not even the same population.

READ THIS CAVEAT BEFORE QUOTING THE GREEN. The run used a **freshly created**
`MIX_TEST_PARTITION`, so its `oban_jobs` started empty and
`ProjectorWorkerEnqueueTest` could not hit the residue described in §4. A green
full suite is therefore evidence about the CODE on main, not about a database
that has been run against before. On a reused partition, expect §4's failure.

## 3b — The proof that §4 is not a code defect, in the same run

The suite run above **generated its own residue**: the partition held 0 rows
before it and **27 committed `scheduled` ProjectorWorker rows after it**. That
turns the next run in the same partition into a control, and it fires:

```
$ psql -tA -d barkpark_testr4w8 -c "select worker, state, count(*) from oban_jobs group by 1,2"
Barkpark.EdgeProjector.ProjectorWorker|scheduled|27

# WITHOUT the fix (test file reverted to origin/main's version):
$ mix test test/barkpark/edge_projector/       # EXIT=2
71 tests, 1 failure

  1) test enqueue/2 — uniqueness across types (lvw-t11-followup-dedup) type-list
     ORDER cannot defeat the dedup (types normalised at enqueue)
     (Barkpark.EdgeProjector.ProjectorWorkerEnqueueTest)
     test/barkpark/edge_projector/projector_worker_enqueue_test.exs:103
     match (=) failed
     code:  assert [job] = all_enqueued(worker: ProjectorWorker)
     left:  [job]
     right: [%Oban.Job{id: 7028, state: "scheduled", queue: "edge_projector",
              worker: "Barkpark.EdgeProjector.ProjectorWorker", ...}, ...]

# WITH the fix, same database, same 27 rows:
$ mix test test/barkpark/edge_projector/       # EXIT=0
71 tests, 0 failures

$ psql -tA -d barkpark_testr4w8 -c "select count(*) from oban_jobs"
27
```

The third command is the one that matters: the row count is **27 before and 27
after** the green run. The `delete_all` runs inside the sandbox transaction and
is rolled back with it, so the fix cannot clobber a shared database's committed
rows or race a concurrent agent's suite on the same box.

## 4 — ProjectorWorkerEnqueueTest: the `oban_jobs` residue is LIVE and much
##     bigger than the August measurement

The mechanism reproduces today. Measured 2026-09-10 against every test database
on this host:

```
$ psql -tA -d barkpark_test -c "select worker, count(*) from oban_jobs group by worker"
Barkpark.EdgeProjector.ProjectorWorker|1284
```

**1284 leftover `scheduled` rows in the unpartitioned `barkpark_test`** — the
August row quoted 519. Every one is a `ProjectorWorker` job. And it is not one
database: 30+ `MIX_TEST_PARTITION` databases on this host carry residue
(`barkpark_testflakypop6dd8` 109, `barkpark_teststudiow14` 88, `…gfr4` 39,
`…historyauthority_0908` 31, `…w15b` 31, `…secw17` 28, …).

WHY IT BITES. `Barkpark.EdgeProjector.ProjectorWorkerEnqueueTest` uses
`Oban.Testing`, and two of its assertions read the WHOLE queue rather than
filtering:

- `test "type-list ORDER cannot defeat the dedup"` — `assert [job] = all_enqueued(worker: ProjectorWorker)`
- `test "same-type save bursts still collapse into ONE job"` — `assert [_only_one] = all_enqueued(worker: ProjectorWorker, args: %{…})`

The SQL sandbox wraps each test in a transaction and rolls it back, but rows
COMMITTED by an earlier non-sandboxed run are plain visible reads inside that
transaction. The sandbox was never going to clean them: there is nothing to roll
back. So `all_enqueued/1` returns residue + the row the test just inserted, and
the singleton match fails.

WHY A FRESH PARTITION HIDES IT. A worker running under a brand-new
`MIX_TEST_PARTITION` gets an empty `oban_jobs` and the test passes — which is
exactly why this keeps being rediscovered as a "flake". The failure is a property
of the DATABASE's history, not of the commit.

THE FIX SHIPPED WITH THIS ROW: a `setup` block in the test file that issues
`Barkpark.Repo.delete_all(Oban.Job)` INSIDE the per-test sandbox transaction.
Because it runs inside the sandbox it is rolled back with everything else, so it
never touches a shared database's committed rows and cannot race a concurrent
agent's suite. It makes the test's own precondition explicit instead of
inheriting whatever the host happens to be carrying.

Manual remedy if you hit this on some other suite before the fix reaches it:

```bash
psql -d barkpark_test$MIX_TEST_PARTITION -c "truncate oban_jobs"
```

## 5 — What the August snapshot in the task row got wrong

The task description names main's red set at `051112568` as SEVEN contexts. On
2026-09-10 that list is wrong in five ways:

1. **"Only two contexts can actually block a merge — Elixir gate and PR references an active task."** It is FOUR: `Cloud gate` and `Console gate` are in `required_status_checks.checks` today.
2. **`Dependency CVE audit (mix_audit)`** — listed as red and "self-LABELLED blocking". Today the context is literally named `Dependency CVE audit (mix_audit over mix.lock, non-blocking)` and it is **success**. It renamed itself and went green.
3. **`Format (advisory)`** — today `Format (mix format --check-formatted, diff-scoped) (27.0, 1.19.5)` is **success**.
4. **`Full production Paper reader audit`, `served-catalog drift audit (advisory)`, `Studio journey - deployed (report mode)`** — none of these three names renders on a settled main commit's check-run set at all any more. They are not "green"; they are ABSENT. A brief that subtracts them subtracts nothing.
5. **Two names main is red on today are not in the August list at all**: `Crown reconcile` and `Stale verdict watch`.

Net: of the August seven, ONE (`Doc budgets + anchors`) is still red for a
reason, one (`Sobelow`) is still red, two went green, three vanished, and two new
ones appeared. **Re-derive; never subtract from a month-old list.**

## 6 — Re-derivation recipes

R1 — the required set (what can actually block):

```bash
python3 -c "
import json; d=json.load(open('.github/required-checks.json'))
print(d['enforced'], d['protection']['required_status_checks'])" | head -c 600
```

R2 — newest settled main commit, then its per-commit red set:

```bash
for sha in $(git log --format=%H -40 origin/main); do
  gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" --paginate |
  python3 -c "
import json,sys; r=json.load(sys.stdin)['check_runs']
print(len(r), sum(1 for x in r if x['status']!='completed'),
      sum(1 for x in r if x.get('conclusion')=='failure'))"
  echo "  ^ $sha"
done
```

The first line with a `0` in the middle column is the newest SETTLED commit. Then
dedupe to the newest run per NAME (a name can appear 2-3 times per sha across
attempts) and read `conclusion`.

R3 — the oban residue, per database:

```bash
psql -l -t | awk -F'|' '{print $1}' | tr -d ' ' | grep '^barkpark_test' |
  while read db; do
    echo "$db $(psql -tA -d "$db" -c 'select count(*) from oban_jobs' 2>/dev/null)"
  done | grep -v ' 0$'
```

## 7 — Host hygiene caveat (recorded, not fixed)

The August measurement was taken while two processes from another session ran
10h47m at 602 CPU-minutes each, deliberately spawning 24 busy-loops apiece. Every
wall-clock timing from that window is worthless. The 2026-09-10 suite run below
was taken on a host also running a multi-worker campaign; treat its DURATION
(531.9s) as an upper bound and its FAILURE SET (empty) as the signal.
