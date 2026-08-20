# Re-derivation recipes — the unrulable review row (PDS wave 27, 2026-07-31)

Verifier lane `unrulable-review-row`. Question: what verdict is honest for
`pds-w25-independent-review-stage-widening`, and — the part that matters more —
does the retrospective independent re-derivation its criteria 1-3 demand
actually hold?

**Authority note, load-bearing.** The primary checkout sits at `a31faa52d`,
which is **NOT a descendant of `origin/main` (`e34031104`)** and is BEHIND it by
461 lines across `stage.ex` / `tasks_controller.ex` / `stage_test.exs`. Running
`mix test` in the primary checkout would have tested the PRE-widening code and
reported a meaningless green. Every run below was executed in a **disposable
detached worktree cut from `origin/main`** at
`…/scratchpad/w27ver` (`git worktree add --detach … origin/main`,
`md5 api/lib/barkpark/tasks/stage.ex` = `fe8d8407446d5b09769416fd7007414e`
matching `git show origin/main:` byte-for-byte), with `api/deps` and
`api/_build/test` copied in from the primary checkout. All source mutations were
reverted with `git checkout <path>`; the worktree was left clean.

**No bp mutation of any kind was made by this lane.** `bp task get` and
`bp search query` only.

| # | Claim | Command |
|---|---|---|
| 1 | The primary checkout is behind `origin/main` on exactly the files under review — so a local test run is L4, not L2 | `git diff origin/main --stat -- api/lib/barkpark/tasks/stage.ex api/lib/barkpark/tasks/transitions.ex api/test/barkpark/tasks/stage_test.exs api/lib/barkpark_web/controllers/tasks_controller.ex; git merge-base --is-ancestor origin/main HEAD` |
| 2 | `stage_test.exs` at `origin/main` is 22 tests / 0 failures | `cd <w27ver>/api && CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 3 | The three refusal fixtures the row names are at `:245` / `:263` / `:272`, NOT the `:254` / `:269` / `:278` printed in the row description and in charter D348 | `git show origin/main:api/test/barkpark/tasks/stage_test.exs \| grep -n 'test "staging to'` |
| 4 | MUTATION — widening `@stageable` to `~w(considering researching open done)` reds **ZERO** tests. Two of the three refusal fixtures are redundant with `@legal_pairs` and cannot detect a widening of the stageable allowlist | `perl -pi -e 's/\@stageable ~w\(considering researching open\)/\@stageable ~w(considering researching open done)/' lib/barkpark/tasks/stage.ex && CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 5 | MUTATION — bypassing the allowlist entirely (`to in @stageable or true`) reds exactly ONE test, `staging to cancelled … is a 422`. That fixture alone constrains `@stageable`; `open→done` and `open→in_progress` are held by `Transitions.@legal_pairs` | `perl -0pi -e 's/if \(to in \@stageable or from == to\)/if (to in \@stageable or true)/' lib/barkpark/tasks/stage.ex && CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 6 | MUTATION — the harness DOES recompile and CAN fail: deleting `{"done","open"}` from `@legal_pairs` reds 2 tests | `perl -0pi -e 's/\{"done", "open"\},\n//' lib/barkpark/tasks/transitions.ex && CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 7 | MUTATION — criterion 2 first half is genuinely constrained: injecting `\|> Map.delete("claim")` into `do_stage`'s content pipeline reds 2 tests (`done → done … claim byte-identical` and `stage(done-task-with-claim, open) … KEEPS the claim untouched`) | `perl -0pi -e 's/(\|> Map\.put\("lifecycle_status", to\))/$1\n      \|> Map.delete("claim")/' lib/barkpark/tasks/stage.ex && CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 8 | PROBE — criterion 2's SECOND half is FALSE for the lease. Adding an `engagement` map to the `blocked`/`in_progress` fixture at `:417` and asserting it survives reds with `ALTERED the lease: nil`. `apply_engagement/5`'s catch-all does `Map.delete(content, "engagement")` for every non-thought target, so a same-state ADJUDICATION silently destroys a live lease | patch `:417` fixture to seed `"engagement" => lease` and assert `row.content["engagement"] == lease`, then `CC=clang MIX_ENV=test mix test test/barkpark/tasks/stage_test.exs` |
| 9 | `claim.ex` never reads or writes `engagement`, so a `blocked`/`in_progress` row CAN carry a live lease into the adjudication door — the #8 path is reachable, not hypothetical | `git show origin/main:api/lib/barkpark/tasks/claim.ex \| grep -n engagement` (no output) |
| 10 | `from` is read from the row inside the advisory-lock transaction (`from = current_status(doc)`), never from caller params — the controller passes only `state` through `Params.fetch_string` with no enum whitelist | `git show origin/main:api/lib/barkpark/tasks/stage.ex \| sed -n '308,330p;576,579p'; git show origin/main:api/lib/barkpark_web/controllers/tasks_controller.ex \| sed -n '629,645p'` |
| 11 | The CLI has no `task stage` implementation and no lifecycle enum at all — the verb is pure manifest dispatch, so the server guard is the sole gate (D349's claim, re-derived by counting not quoting) | `grep -rln 'stage' internal/cli/*.go \| grep -v _test` (nine files, all `cloud_*` / `run.go` / `setup_cmd.go` / `vercel_cmd.go`; none is tasks) |
| 12 | The row itself is `open`, 0/4, criterion 4 is `[MERGE-GATED] … before pds-w25-stage-terminal-widening merged` | `bp task get pds-w25-independent-review-stage-widening -o json` |

## The one line that matters

Criteria 1-3 are **discharged and CONFIRMED** by the runs above, with two
qualifications the row did not anticipate: the refusal fixtures constrain the
transitions TABLE, not the stageable allowlist (rows 4-5), and the "no lease is
altered" half of criterion 2 is **refuted** (rows 8-9). Criterion 4 is
unsatisfiable as written — the merge landed — and no future act can change that.
