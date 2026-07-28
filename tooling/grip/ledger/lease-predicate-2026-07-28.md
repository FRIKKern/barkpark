# Re-derivation recipes — lease-predicate (honest gates wave 4, 2026-07-28)

Verifier lane: DECIDE the `PR references an active task` lapse predicate before it is
made required-by-name. The three named candidates (P1 assignee-backed, P2 renew-on-push,
P3 goal delegation) are all measured below; two are refuted by their own numbers and one
by the repo's own comment. The recommendation is P4 (claim-live-at-PR-open), proven on
the live ledger against four real open PRs and on four synthetic fixtures.

| # | Claim | Command |
|---|---|---|
| 1 | The live gate REDS `hgw2-s5-ci-verdict-reader` today at ~26,000s past the 21,600s grace (exit 1) | `git show origin/main:scripts/pr-task-gate.sh > /tmp/gate.sh && TASK_ID=hgw2-s5-ci-verdict-reader bash /tmp/gate.sh; echo "LIVE_EXIT=$?"` |
| 2 | `content.assignee == claim.previous_worker` is TAUTOLOGICAL, not empirical: `do_claim` writes `assignee = worker_id` (claim.ex:315) and the reap writes `previous_worker = old_claim["worker"]` (ttl_sweeper.ex ~:371) — the same value | `git show origin/main:api/lib/barkpark/tasks/claim.ex \| sed -n '300,320p'` · `git show origin/main:api/lib/barkpark/tasks/ttl_sweeper.ex \| sed -n '365,395p'` |
| 3 | The only writer that can BREAK the agreement is `release`, which deletes `assignee` (release.ex:142) — a state the gate already reds via the `released_ge_expired` ordering clause | `git show origin/main:api/lib/barkpark/tasks/release.ex \| sed -n '138,145p'` · `grep -rn '"assignee"' api/lib/barkpark/tasks/` |
| 4 | Ledger-wide (3,363 tasks): 287 carry `claim.previous_worker`; 275 agree with `assignee`, **0 disagree**, 12 have no assignee (all released) | `python3` loop over `https://guerrilla.barkpark.cloud/v1/data/query/production/task?limit=500&offset=N` comparing `claim.previous_worker` to `assignee` |
| 5 | P1 (assignee-backed, grace dropped) passes **108 of 109** open lapsed tasks — including claims lapsed 18.6 days — i.e. it stops discriminating | same query; predicate `lifecycle=='open' and assignee==claim.previous_worker and not claim.released_at` |
| 6 | P3 (goal delegation, any child `in_progress`) passes **0 of 109** open lapsed tasks right now | same query; build `parent_id` → children map, count `in_progress` children |
| 7 | Current grace (21,600s) passes **20 of 109** open lapsed tasks | same query; predicate `now - expired_at <= 21600` |
| 8 | On the 13 identifiable open PRs: grace passes 4, P1 passes 13, P4 passes 11 and refuses #6631 + #5901 (epic claims that lapsed 13.8 d / 15.0 d BEFORE those PRs were opened) | `gh pr list --state open --limit 40 --json number,createdAt,body` joined to the ledger on the `Task:` trailer |
| 9 | P2 (CI-side renew) is refuted in-repo by the gate's own comment: "a CI-side renewal bumps claim.epoch and would fence the holder out of their own close" | `git show origin/main:scripts/pr-task-gate.sh \| sed -n '295,302p'` |
| 10 | `do_renew` MERGES into the claim while `do_claim` REPLACES it — so a re-claim destroys `previous_worker` | `git show origin/main:api/lib/barkpark/tasks/claim.ex \| sed -n '296,320p;372,390p'` |
| 11 | P4 PASSES #6414 (claim live at PR open, reaped in review) and REFUSES #6631/#5901, against the LIVE ledger | `PR_OPENED_AT=2026-07-27T21:27:32Z TASK_ID=hgw2-s5-ci-verdict-reader bash /tmp/gate-p4.sh` · same with `2026-07-28T11:33:47Z` + `bp-cloud-site-spawner-epic` |
| 12 | P4 refuses a 30-day-abandoned task that P1 passes (fixture `abandoned-30d`, assignee==previous_worker) | serve fixtures on `127.0.0.1:8791`, `LEDGER_BASE=http://127.0.0.1:8791 PR_OPENED_AT=<now> TASK_ID=abandoned-30d bash /tmp/gate-p4.sh` vs `LAPSE_GRACE_SECONDS=999999999 bash /tmp/gate.sh` |
| 13 | P4 keeps every other clause honest: released → red, never-claimed → red, future `expired_at` → red (the -300s skew clause must be RETAINED; P4 alone would pass a future expiry) | same fixture server, `TASK_ID` in `released-task never-claimed lapsefuture lapseskew` |
| 14 | P4 REFUSES when `PR_OPENED_AT` is absent — it never falls open | `TASK_ID=hgw2-s5-ci-verdict-reader bash /tmp/gate-p4.sh; echo $?` → 1 |
| 15 | `created_at` is on the real PR payload and is stable across `synchronize`/`edited` | `gh api repos/FRIKKern/barkpark/pulls/6414 --jq '{created_at,updated_at}'` |
| 16 | The existing 62-assertion selftest is green on origin/main; ~13 lapse fixtures + 2 grace-tuning fixtures (lines 195-209) are the bounded migration cost | `bash scripts/pr-task-gate.test.sh 2>&1 \| tail -5` · `grep -n 'lapse\|GRACE' scripts/pr-task-gate.test.sh` |
| 17 | Three of the 16 open PRs (#6650, #6028, #2907) carry NO extractable `Task:` trailer — they red for a different reason than the lease and P4 does not help them | `gh pr list --state open --limit 40 --json number,body` + `scripts/pr-task-gate.sh --extract-task-id` |
