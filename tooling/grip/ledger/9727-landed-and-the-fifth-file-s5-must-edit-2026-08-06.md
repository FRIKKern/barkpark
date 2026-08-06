# 9727 landed; s5 is unblocked; and s5's file set is missing a gate file

Verifier row, deploy-reliability wave 4, assignment `9727-and-controller-edge`.
Every line below is a command you can re-run. Baseline: `origin/main` =
`0c451e5edb07659498c0f6d83be0a17c779dc0a0` (2026-08-06T11:41:00Z).

## 1. #9727 is MERGED, not pending

```
gh pr view 9727 --json state,mergeStateStatus,mergedAt -q '[.state,.mergeStateStatus,.mergedAt]'
# ["MERGED","UNKNOWN","2026-08-06T11:31:45Z"]

gh pr view 9727 --json mergeCommit -q .mergeCommit.oid
# 9edfd15a649e44779fdf349326d2e3078e6f4c2e   (squash — PR head 7c1f80825 is NOT an ancestor of main)
```

Do NOT judge landing with `git merge-base --is-ancestor pr9727 origin/main` — it
answers NO for a squash merge. Judge by CONTENT:

```
git show origin/main:api/lib/barkpark_web/controllers/site_deploy_controller.ex | grep -n site_provision_failed
# 40:    * **500** `site_provision_failed` — the site's SOURCE could not be
# 113:      {:error, {:provision_failed, reason}} ->
# 127:            code: "site_provision_failed",
```

Conflict state against current main: `git merge-tree $(git merge-base origin/main
pr9727) origin/main pr9727 | grep -c '<<<<<<<'` → `0`.

`ae73f6340` (#9729, the provisioner src fix) is contained in BOTH:
`git merge-base --is-ancestor ae73f6340 origin/main` → rc 0.

## 2. The fifth file — an allowlist gate s5's file set does not name

`dr-w3-s5-door-refuses-box-at-capacity` lists four files. Emitting
`code: "box_at_capacity"` from the controller reds a FIFTH:
`api/test/barkpark_web/contract/error_code_coverage_test.exs`.

The guard scans `lib/barkpark_web/controllers/**/*.ex` for static `code: "..."`
literals and asserts each is in `Errors.known_codes/0` ∪ `@offspec_codes`.
#9727 had to add `site_provision_failed` to `@offspec_codes` for exactly this
reason (7 added lines in that file).

Proof the new code is in NEITHER set, without mutating the repo:

```
cd api && CC=clang MIX_ENV=test mix run --no-start -e \
 'k=Barkpark.Content.Errors.known_codes(); IO.puts(MapSet.size(k)); \
  IO.puts(MapSet.member?(k,"box_at_capacity")); IO.puts(MapSet.member?(k,"already_running"))'
# 65
# false
# false      <- already_running is offspec too; box_at_capacity is in neither list
```

Baseline green (so the red would be s5's own):

```
cd api && CC=clang MIX_ENV=test mix test test/barkpark_web/contract/error_code_coverage_test.exs
# 2 tests, 0 failures   (0.06s)
```

## 3. s5's line anchors are pre-#9727 and now wrong

Re-derived on `origin/main`:

| s5 says | actually on main |
|---|---|
| already_running clause `:86-94` | **91-99** |
| `trigger/1` @spec `:203` | **285-289** |
| D86/D87 "cost nothing" comment `:407-412` | **571-572** |
| (unnamed) moduledoc 409 bullet | **34-35**; new 500 bullet 40-44 |
| (unnamed) `handle_call({:trigger, …})` | **405-419**, `running_slug?` if at 413 |

```
git show origin/main:api/lib/barkpark_web/controllers/site_deploy_controller.ex \
  | grep -n '^      {:error\|^    \* \*\*'
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex \
  | grep -n 'def trigger\|handle_call({:trigger\|cost nothing'
```

## 4. No fourth editor; the two "unexplained" worktrees are wave-3 residue

```
git -C .claude/worktrees/wf_0eb8c2da-393-30 log --oneline -1
# f37e2e0f5 fix(cloud): make the deferral taxonomy reason-aware …
gh pr list --state all --head loop-epic/the-deferral-taxonomy-stops-being-reason-2 \
  --json number,state,mergedAt -q '.[]|[.number,.state,.mergedAt]|@tsv'
# 9783  MERGED  2026-08-06T11:05:47Z
```

Its `box_at_capacity` lines are byte-identical to main:

```
for f in cloud/lib/barkpark_cloud/deploy_ledger.ex \
         cloud/test/barkpark_cloud/deploy_ledger_test.exs \
         cloud/test/barkpark_cloud/sites_deploy_test.exs; do
  diff <(grep -n box_at_capacity ".claude/worktrees/wf_0eb8c2da-393-30/$f") \
       <(git show "origin/main:$f" | grep -n box_at_capacity) && echo IDENTICAL
done
# IDENTICAL x3
```

`-32` is branch `charter-w3` (no PR, `gh pr list --head charter-w3` → empty); its
charter and ledger files are byte-identical to main's. Both are stale checkouts
of already-landed wave-3 work, not a hidden editor.

## 5. s5's file set is uncontested

```
gh pr list --state open --limit 100 --json number,files \
 -q '.[]|select((.files|map(.path)|join(" "))|test("site_deploy_controller|deploy_runner|sites/|deploy_ledger"))|.number'
# (empty — 13 open PRs, all 13 have a populated .files field)
```

The `.files`-populated count is stated because an empty filtered result and an
absent field look identical (bespoke-checks-lie shape #5).

## 6. `box_at_capacity` does not exist in api/ at all

```
git grep -n box_at_capacity origin/main -- api/ ; echo rc=$?
# rc=1
git grep -c box_at_capacity origin/main -- cloud/ ; echo rc=$?
# origin/main:cloud/lib/barkpark_cloud/deploy_ledger.ex:1
# origin/main:cloud/test/barkpark_cloud/deploy_ledger_test.exs:1
# origin/main:cloud/test/barkpark_cloud/sites_deploy_test.exs:3
# rc=0
```

The rc is captured from `git grep` itself, not from a following `echo` — the
first draft of this check reported `rc=0` because `echo "(rc=$?)"` had already
overwritten `$?`.

## 7. There is already an open task for the code handshake

`dr-w3-s3-followup-capacity-code-handshake` (priority 1, GitHub #9773) exists to
confirm the cap emits the literal `box_at_capacity` that
`deploy_ledger.ex:318` keys on. It is s5's acceptance criterion in another
document — Decide should fold it into s5 or make it s5's merge gate, not leave
it as a separate follow-up nobody runs.
