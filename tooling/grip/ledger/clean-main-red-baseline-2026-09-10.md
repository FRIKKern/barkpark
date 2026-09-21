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

## 8 — FOURTH residue signature, added 2026-09-20: `claude_chat_cloud_session_test.exs:170`

Sections 3b and 4 name three residue reds. There is a FOURTH, and until this entry
it was not written down anywhere a builder would look — so it kept being read as a
fresh red caused by whatever diff happened to be under it.

**Signature.** `BarkparkWeb.Studio.ClaudeChatCloudSessionTest`, the test

    dead-sandbox binding clears on a loud reuse failure
    (connectors D139 half B / D152-D156)
    turn 3 mints FRESH after the bound sandbox vanishes on turn 2
    — honest reset, not --resume into the void

fails at `api/test/barkpark_web/studio/claude_chat_cloud_session_test.exs:170` with

    a loud reuse failure (nonzero exit) must clear the dead sandbox binding ("sbx-stub-1")
    code: assert match?(%{cloud_sandbox_id: nil}, session_after),
    stacktrace:
      test/barkpark_web/studio/claude_chat_cloud_session_test.exs:220: (test)

**Reproduction.** It reds in a DIRECTORY run and passes ALONE. Under a private
`MIX_TEST_PARTITION`:

    cd api && ../scripts/mix-test-strict.sh test/barkpark_web/studio/ test/barkpark_web/components/
    # 823 tests, 1 failure  — the :170 test
    cd api && ../scripts/mix-test-strict.sh test/barkpark_web/studio/claude_chat_cloud_session_test.exs
    # 4 tests, 0 failures

**It is NOT an order dependence you can fix, and the "find the leaking fixture"
arm is VACUOUS — do not spend a round on it.** That was tried and ruled out, with
controls: the red was non-reproducible as an ordering effect across SIX directory
runs, and an instrumented run measured ZERO live Recorders, admission leases and
bindings at that test's own entry. It is host contention on subprocess scheduling,
the same family as #17605 and spd-b38. The adjacent log noise on a red run —
`Postgrex.Protocol … disconnected`, `** (stop) {:app_server_exit, 17}`,
`Req.TransportError connection refused` — is that contention, not a code defect.

**Why this entry exists rather than a fix.** A red nobody has written down is
indistinguishable from a red your diff caused, and the rule every lead is given —
never accuse the diff under a flapping red — cannot be applied to a signature that
is not recorded. First filed as `task-9ffbd1b42bcf189f` on 2026-09-11 by
studio-r11-w2 off `task-a905d8016760e72e` (#17796); the leak-hunt half landed in
#19209. Observed again on 2026-09-20 in `Elixir gate` run 35505321451, on a PR
whose entire diff was two Studio switcher TEST files — nothing near chat or
sandbox code — which is exactly the false accusation this entry prevents.

**What to do when you hit it.** Confirm the failing test is this one and only this
one, then re-fire the gate with `gh pr update-branch <pr>` (a new head, a fresh
run) rather than `gh run rerun`. If a run fails with this signature PLUS anything
else, the something else is yours.

---

# 2026-09-20 — re-derivation (the 2026-09-10 section above is a RECORD; nothing in it was edited)

Derived 2026-09-20 between 14:33Z and 14:52Z, task-fad8293a72162376, by the
recipe in §6 above: per-commit `GET /repos/FRIKKern/barkpark/commits/<sha>/check-runs`
(`--paginate`), newest run per NAME, never a run rollup. Everything below is
the check-run API's own `conclusion` plus a line lifted from the failing JOB's
log. Same caveat as §2: re-derive, do not subtract from this list next week.

## 2026-09-20 §A — the commit this is measured on

`git log -20 origin/main`, walked newest-first, counting `status != "completed"`
per sha. The first ten shas (`2cb49d603` … `8d102e81a`) all carried queued or
in-progress runs — from 29 down to 1 — so none of them is settled. The first
with **zero** non-completed check-runs:

**`769c39bd6959f1adb7428b72d9dde4237421640d` — 2026-09-20 15:28:39 +0200
(13:28:39Z) — "fix(gates): doc-gates red on main's tip — cite by SYMBOL…" (#19458).**

* raw check-runs: **131**; **119 distinct names**; non-completed: **0**
* names whose newest run is not `success`/`skipped`/`neutral`: **4**

`2cb49d603` (main's tip when this was written) is **UNMEASURED** — 29 of its 34
check-runs were still non-completed. A tip sha essentially never settles during
a campaign; that is unchanged from 09-10.

## 2026-09-20 §B — main's red set at `769c39bd6…`, each with its job log line

| Context | newest run | Failure line, quoted from the JOB log |
|---|---|---|
| `Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)` | run `35513615817`, job `106086477236` | `Traversal.FileModule: Directory Traversal in `File.read!` - Low Confidence` / `File: lib/barkpark/search/golden_eval.ex` / `Line: 30` / `Function: run:25` / `Variable: path`. The step that exited 1 is `mix sobelow --skip --exit Low`. |
| `Sobelow baseline does not swallow its own inline waivers (blocking)` | run `35513615817`, job `106086477255` | `FAIL: 1 baseline entries no longer point at a construct of their own type.` … `STALE lib/barkpark/search/golden_eval.ex:23 Traversal.FileModule — line holds no read! call:` · `checked 17 of 24 baseline entries (7 skipped: no per-line anchor)`. Failing step: `Every baseline entry still points at a construct of its own type`. |
| `Security gate` | run `35513615817`, job `106088827253` | `FAIL    sobelow: MEASURED-DEFECT — it ran and found a defect this head` · `FAIL    sobelow-inline-overlap: failure` · `##[error]Security gate: at least one upstream job is not in the allow-set (see above).` It is the aggregate of the two rows above — one cause, three names. |
| `orphan harnesses (local-update · pdf-efficiency-proof · refute-on-absence)` | run `35513615793`, job `106088936496` | `FAIL  (g) the real tree reds` / `RED  api/test/barkpark/content/dedup_wall_test.exs — 1 refute-on-log site(s) in a module that is async: true and uses capture_log` / `…/dedup_wall_test.exs:458` · `SELFTEST FAILED: 1 of 9 arms failed`. |

One root cause (`golden_eval.ex`) produces three of the four names. The fourth
is one test file.

**Read forward before you subtract.** On `262255d4c` (#19493, "golden_eval's
waiver rides run/3", merged 16:14 +0200 — NOT settled, 10 non-completed at
read time) `Sobelow baseline does not swallow its own inline waivers (blocking)`
had already flipped to `success`, `Sobelow static analysis…` was still running
(`conclusion: null` — **never ran to a verdict**, which is neither red nor
green), and a name absent from the table above, `Security gate shape ratchet`,
was `failure`. That is a partial read of an UNSETTLED commit and is recorded as
such; it is not a claim that main is clean.

## 2026-09-20 §C — the required four on a main PUSH

`.github/required-checks.json` at `2cb49d603be35d15654222fc4b989a8cdd15d3e1`
still carries exactly four contexts with `enforced: true`,
`required_status_checks.strict: false`: `Cloud gate`, `Console gate`,
`Elixir gate`, `PR references an active task`. No change from §1 above.

They are **PR-keyed**, and on a push to main the set that renders depends on the
diff's paths. On all five settled commits measured below:

| Required context | on `769c39bd6…` | why |
|---|---|---|
| `Elixir gate` | `success`, run `35513615809` | `elixir.yml` has a `push: branches:[main]` arm and it dispatched |
| `Cloud gate` | `success`, run `35513615784` | `cloud.yml` push arm dispatched |
| `Console gate` | **ABSENT — never ran** | `console-harness.yml`'s push arm is paths-filtered; this diff matched none, so NO check-run exists. Absent is not green. |
| `PR references an active task` | **ABSENT — never ran** | `pr-task-gate.yml` is `on: pull_request:` only. It can never render on a push to main. |

Citations, each the newest **main push-arm** run of its workflow, with the line
its own log printed:

* **Elixir** — run `35513615809` (`elixir.yml`, `event=push`), sha
  `769c39bd6…`, gate job `106090666050`. Test job `106086606533`:
  `30 doctests, 21837 tests, 0 failures, 33 excluded`. Gate line:
  `Elixir gate: every upstream job either succeeded or was legitimately not dispatched.`
* **go-tests** — run `35513502375` (`go-tests.yml`, `event=push`), sha
  `7d7ea3318`, `conclusion: success`. Job `106085502042` (`go vet + test`):
  **36 packages `ok`, 0 `FAIL`**. Gate job `106086535169`:
  `Go gate: every upstream job either succeeded or was legitimately not dispatched.`
  There is **no `go-tests` check name on `769c39bd6…` at all** — the Go push arm
  did not dispatch on that diff.
* **cloud** — run `35513615784`, sha `769c39bd6…`, `Cloud gate` job
  `106088449968`. Test job `106086599460`: `5519 tests, 0 failures`.
* **console** — run `35511130085` (`console-harness.yml`, `event=push`), sha
  `45c3e41d6`, `conclusion: success` — the newest main push run that dispatched.
  Gate job `106082413862`:
  `Console gate: every upstream job either succeeded or was legitimately not dispatched.`
  Seven harness jobs ran (CSSOM oracle, CSSOM parity, client unit, billing tier
  floor, overflow guard, path-escape ratchet, dispatch), all `success`.

The gate jobs' own logs say what a green means, verbatim:
`Console gate is green because this diff touched none of its declared path sets,
NOT because anything was tested.` A gate that did not dispatch is recorded here
as **never ran**, never as a pass.

## 2026-09-20 §D — stability across the five newest SETTLED main commits

Settled = zero non-completed check-runs at read time. Newest first:
`769c39bd6` (#19458), `fbe29925e` (#19485), `b220eb9e6` (#19479),
`610aa6cb5` (#19469), `7d7ea3318` (#19384).

| name | 769c39b | fbe2992 | b220eb9 | 610aa6c | 7d7ea33 | reading |
|---|---|---|---|---|---|---|
| `Sobelow static analysis (…) (27.0, 1.18.1)` | RED | RED | RED | RED | RED | 5/5 — main's own |
| `Sobelow baseline does not swallow its own inline waivers (blocking)` | RED | RED | RED | RED | RED | 5/5 — main's own |
| `Security gate` | RED | RED | RED | RED | RED | 5/5 — main's own (aggregate of the two above) |
| `Doc budgets + anchors` | success | RED | RED | RED | RED | **4/5 red, and the green is the NEWEST** — fixed by #19458, which is `769c39bd6` itself |
| `orphan harnesses (local-update · pdf-efficiency-proof · refute-on-absence)` | RED | ABSENT | ABSENT | ABSENT | ABSENT | 1/1 where it rendered — **UNMEASURED as a rate**: n=1 |
| `Crown reconcile` | success | success | success | success | success | 0/5 |
| `Stale verdict watch` | success | success | success | success | success | 0/5 |
| `Cloud gate` | success | success | success | success | success | 0/5 |
| `Elixir gate` | success | success | success | success | success | 0/5 |
| `Console gate` | ABSENT | ABSENT | ABSENT | ABSENT | ABSENT | never ran on any of the five |
| `PR references an active task` | ABSENT | ABSENT | ABSENT | ABSENT | ABSENT | never ran (pull_request-only) |
| `Go gate` | ABSENT | ABSENT | ABSENT | ABSENT | success | dispatched on one of five |

Distinct-name counts differ wildly across these five settled shas — 119, 52, 47,
47, 58 — because dispatch is path-driven. **A name missing from your PR's set is
usually dispatch, not deletion.**

## 2026-09-20 §E — every 2026-09-10 row, resolved

| 09-10 row | status on 2026-09-20 | evidence |
|---|---|---|
| `Doc budgets + anchors` (`#123` read as a CSS hex in `internal/cli/tasks_stamp_cmd.go:224`) | **RESOLVED — #19458** (`769c39bd6`, "fix(gates): doc-gates red on main's tip — cite by SYMBOL, and refresh the two snapshots the docs outran") | `success` on `769c39bd6`, RED on all four settled commits before it |
| `Sobelow static analysis (…)` | **STILL RED, DIFFERENT CAUSE.** 09-10's finding was `deploy_runner.ex:2191 File.rm_rf`; 09-20's is `golden_eval.ex:30 File.read!`. Not the same defect — do not carry the old citation | job `106086477236` log, quoted in §B |
| `Crown reconcile` | **RESOLVED — gone, cause unknown.** `success` on 5/5 settled commits; no fixing PR identified by this derivation | §D table |
| `Stale verdict watch` (HTTP 502/403 secondary rate limit) | **RESOLVED — gone, cause unknown**, and the 09-10 row already called it self-clearing transport. `success` on 5/5 | §D table |
| §3's green full Elixir suite (`30 doctests, 20020 tests, 0 failures`) | **SUPERSEDED, still green**: CI's own push-arm run on `769c39bd6…` prints `30 doctests, 21837 tests, 0 failures, 33 excluded`. The population grew by 1817 tests in ten days | job `106086606533` |
| §4 `ProjectorWorkerEnqueueTest` / `oban_jobs` residue | **UNMEASURED.** No database on any host was read for this derivation. §4's mechanism is untouched by anything above; treat it as still live until someone re-runs recipe R3 | — |

New since 09-10, in both directions: **added** `Sobelow baseline does not
swallow its own inline waivers (blocking)`, `Security gate`, `orphan harnesses
(…)`. **Removed** `Doc budgets + anchors`, `Crown reconcile`,
`Stale verdict watch`. Of the 09-10 four, exactly ONE name is still red, and
even that one is red for a different finding.

## 2026-09-20 §F — what this derivation did NOT measure

Written down rather than guessed at.

* **No full Elixir suite was run locally.** §C's test counts are CI's, off the
  push arm. §3's local-worktree measurement was not repeated.
* **No `oban_jobs` census** (recipe R3). §4 is carried forward UNMEASURED.
* **Live branch protection was not read from the API.** §C's four contexts come
  from the committed `.github/required-checks.json`. `scripts/required-checks-verify.sh`
  is the three-way check and was not run here as a network read.
* **`orphan harnesses (…)` has n=1.** It rendered on exactly one of the five
  settled commits, so "5/5" vs "flapping" is **UNMEASURED** for it.
* **Everything about `262255d4c` and newer is UNSETTLED** (§B). The forward note
  there is a partial read, deliberately not folded into §B's table or §D's rates.
* **DISPUTED — "Sobelow red is api's":** the ORDER that filed this work said
  the Sobelow red re-routed to `golden_eval.ex`, which §B confirms; it did not
  say a second name (`…inline waivers…`) and a third (`Security gate`) ride the
  same cause. The filing's count of main's red names would have been 1; it is 4.

## 2026-09-20 §G — filing claims, checked one by one

The order that produced this section carried five "known context" claims. Every
one was verified against the API rather than transcribed; two were incomplete.

1. **"#19417 (`9f931a6f8`) cleared 31 briefless fixtures"** — **NOT
   CHECKED.** No check-run name in the 09-20 red set traces to it, so it did not
   bear on this derivation. Recorded as unverified, not as true.
2. **"the PdsRecordParityTest fleet blocker was cleared by deploy #19490
   (`6c1436c2d`)"** — **NOT CHECKED** for the same reason. `6c1436c2d` reads as
   settled with 3 non-success names in the walk, but no per-name read was taken.
3. **"go-tests was red 6 runs on `producer_contract_test.go:495` and green at
   `45c3e41d6` (#19418)"** — **CONFIRMED, exactly.** Main push-arm `go-tests`
   runs, newest-last: `35432263069` (`8f50e6a2b`) fail, `35432331897`
   (`8866c1fdd`) fail, `35434455724` (`e58d8bbcd`) fail, `35435517787`
   (`0dcbd9bdb`) fail, `35502477068` (`042916f6e`) fail, `35506090842`
   (`f867e60f9`) fail — six — then `35511130127` (`45c3e41d6`) **success**.
   Job `106066237074` on the last red prints
   `--- FAIL: TestSiteBuildLogBytesDecoderMatchesProducer (0.00s)` and
   `producer_contract_test.go:495: the envelope key "box_error" is not written anywhere in BuildLogBytes`.
   (Two `cancelled` runs sit inside that window — `35432314492`, `35432273878` —
   and are not counted as reds.)
4. **"Sobelow/Security red is api's (`golden_eval.ex`)"** — **CONFIRMED on the
   file, INCOMPLETE on the scope.** See the DISPUTED entry in §F.
5. **"elixir-nightly, main-gate-watch, chronicle-paper (owner token, 401) are
   scheduled reds"** — **NOT MEASURED.** None of those three names appears in
   the 119-name check-run set on `769c39bd6…`. A scheduled workflow's run is not
   keyed to a main commit, so this derivation's instrument cannot see it either
   way. Written as never-measured, not as green.

## 2026-09-20 §H — the recipe, as actually run

```bash
for sha in $(git log --format=%H -20 origin/main); do
  gh api "repos/FRIKKern/barkpark/commits/$sha/check-runs?per_page=100" --paginate > "cr-$sha.json"
done
# then, per sha: dedupe to the newest run per NAME by started_at, and count
#   len(runs), sum(status != "completed"), sum(conclusion not in {success,skipped,neutral})
# the first sha whose middle column is 0 is the newest SETTLED commit.
```

QUOTE THE URL. In zsh an unquoted `?per_page=100` is a glob and the call dies
before it is made. Then, for each non-success name, follow `details_url`'s run
id to `actions/runs/<id>/jobs`, take the job whose `conclusion` is `failure`,
and read `actions/jobs/<job>/logs` — the check-run's own `output` is frequently
empty, and a run's `conclusion` still lies under `continue-on-error`.
