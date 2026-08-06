# cch-w34 · fence-d31-recheck — re-derivation recipes (2026-08-06)

Verifier assignment `fence-d31-recheck`, cloud-console-hardening wave 34. Every row
is a literal command that re-derives the fact from scratch. All reads are L3
(unmerged branch / bp ledger) unless the command says `origin/main`.

| # | Fact | Command |
|---|---|---|
| 1 | PR #9677 is still OPEN, MERGEABLE, mergeStateStatus CLEAN, not a draft — it can merge at any moment | `gh pr view 9677 --json state,mergeable,mergeStateStatus,isDraft -q '[.state,.mergeable,.mergeStateStatus,(.isDraft\|tostring)]\|@tsv'` |
| 2 | All four required contexts (Elixir gate, Cloud gate, Console gate, PR references an active task) PASS on #9677 | `gh pr checks 9677 \| grep -E '^(Elixir gate\|Cloud gate\|Console gate\|PR references an active task)'` |
| 3 | D31 exists verbatim on #9677 and is UNAMENDED — the only commit touching the charter file is d021e4cf (00:20 UTC); dad4b33b is a gate re-fire, 3746ccfe adds one ledger file | `gh pr view 9677 --json commits -q '.commits[]\|[.oid[0:8],.committedDate,.messageHeadline]\|@tsv'; gh pr diff 9677 \| grep -n -A11 'D31 — CORRECTS'` |
| 4 | D31 cedes the console render path and claims `deploy/**`, `api/lib/barkpark/sites/**`, `internal/builder/**` | `gh pr diff 9677 \| sed -n '151,162p'` |
| 5 | EIGHT dr-w2 slices exist (s1–s8), all `lifecycle_status: open`, 0 criteria met, no claim, no assignee | `bp task get task-fb4fb869490b4213 -o json \| python3 -c 'import sys,json;[print(c["doc_id"],c["lifecycle_status"],c["criteria_progress"]) for c in json.load(sys.stdin)["children"] if "dr-w2" in c["doc_id"]]'` |
| 6 | The bare id `dr-w2-s4` is NOT a task — the real slug is `dr-w2-s4-scrub-knows-our-own-token` | `bp task get dr-w2-s4 -o json; bp task get dr-w2-s4-scrub-knows-our-own-token -o json \| head -c 200` |
| 7 | dr-w2-s3 fences `cloud/lib/barkpark_cloud/sites/deploy.ex` + `cloud/test/barkpark_cloud/sites_deploy_test.ex` | `bp task get dr-w2-s3-poll-grace-5xx-and-named-refusal -o json \| grep -o '[A-Za-z0-9_./-]*\.exs\?'` |
| 8 | dr-w2-s6 fences `cloud/priv/static/__app.test.mjs:10050`, `deploy/**`, `api/lib/barkpark/sites/deploy_request.ex:68` — and NOT `app.js` render code | `bp task get dr-w2-s6-engine-one-extractor-health-slow-vs-broken -o json \| grep -o '[A-Za-z0-9_./-]*\.\(mjs\|sh\|ex\)[:0-9]*' \| sort -u` |
| 9 | dr-w2-s4 fences `cloud/lib/barkpark_cloud/failure_copy.ex` + `api/lib/barkpark/auth.ex` — no console render | `bp task get dr-w2-s4-scrub-knows-our-own-token -o json \| grep -o '[A-Za-z0-9_./-]*\.ex[:0-9]*' \| sort -u` |
| 10 | ZERO dr-w2 code branches exist on origin — the only deploy-reliability ref is the charter branch | `git fetch origin --quiet; git branch -r \| grep -iE 'dr-w2\|deploy-rel'` |
| 11 | ZERO dr worktrees among 244 registered worktrees | `git worktree list \| grep -icE 'dr-w2\|deploy.reliab\|deploy-truth'; git worktree list \| wc -l` |
| 12 | The digest's id `cch-w33-bl-console-narration-latch` does not resolve; the real row is `cch-w33-bl-console-narration-latch-is-invisible-control-plane-side`, parent `cloud-console-hardening-epic`, open+unclaimed | `bp task get cch-w33-bl-console-narration-latch -o json; bp search query "narration latch" \| grep -o 'cch-w33-bl-[a-z-]*'` |
| 13 | The cch narration row's criterion 2 says "without a migration or a **builder change**" — render half only, inside D31's cession | `bp task get cch-w33-bl-console-narration-latch-is-invisible-control-plane-side -o json \| python3 -m json.tool \| grep -A2 'criterion'` |
| 14 | The dr twin `dr-bl-builder-console-narration-latch` (internal/builder, open+unclaimed) has a criterion that reaches the READ side: "readable as truncated rather than as complete" | `bp task get dr-bl-builder-console-narration-latch -o json \| grep -o 'readable as truncated[^"]*'` |
| 15 | TWO open unclaimed dr rows both aim a failure_class pill at `cloud/priv/static/app.js`: `task-54326937e919e2cf` and `dr-bl-console-failure-class-pill` | `bp task get task-54326937e919e2cf -o json \| head -c 200; bp task get dr-bl-console-failure-class-pill -o json \| head -c 200` |
| 16 | The cch charter already names task-54326937e919e2cf as a fenced cross-epic collision (D379 region fence) | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '204,214p'` |
| 17 | Wave-33's three builder PRs (#9687 build-console tail, #9688 5xx reader, #9689 gate disclosure) all MERGED 2026-08-06T01:17Z — origin/main already carries them | `for b in the-build-console-stops-printing-a-tail--2 the-captured-5xx-body-gets-a-reader-3 three-required-gates-conclude-success-ha-4; do gh pr list --head "loop-epic/$b" --state all --json number,state,mergedAt -q '.[]\|[.number,.state,.mergedAt]\|@tsv'; done` |

Caveat for Decide: rows 1–4 read an UNMERGED branch. #9677 is CLEAN with all four
required contexts green, so D31 can become law on `origin/main` between this read
and builder launch — but nothing in D31 gets WORSE for us if it merges; the risk is
the opposite direction (an amendment before merge). Re-run row 3 at builder-launch.
