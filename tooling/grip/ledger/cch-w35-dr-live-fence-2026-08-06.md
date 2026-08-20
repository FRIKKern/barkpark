# cch wave 35 — [dr-live-fence] re-derivation recipes (2026-08-06 09:05-09:15 UTC)

Question: is deploy-reliability **wave 3** in flight, and who owns `registry.ex` and
`failure_copy.ex` right now? Verdict: **wave 3 does not exist; wave 2 is in flight and is in its
MERGE-PENDING phase with all claims lapsed.** Every row below re-derives from scratch.

| Claim | Command |
|---|---|
| origin/main tip at read time = `c73bbc07c` | `git fetch origin -q && git rev-parse origin/main` |
| 12 open PRs; only #9731 touches `failure_copy.ex`; NONE touch `registry.ex` | `for n in $(gh pr list --state open --json number -q '.[].number'); do echo "== $n"; gh pr diff $n --name-only \| grep -E 'registry\.ex\|failure_copy\|app\.js' \|\| echo '  none'; done` |
| deploy-reliability epic has 52 children and **zero `dr-w3-*`** | `bp task get task-fb4fb869490b4213 -o json \| python3 -c "import sys,json;d=json.load(sys.stdin);print(d['child_count'], len([c for c in d['children'] if c['doc_id'].startswith('dr-w3')]))"` |
| every open `dr-w2-*` row has `claim.worker == null`, expiries 03:08–03:24Z | `for t in dr-w2-s1-recorder-build-id-keyed-log dr-w2-s2-provision-rmrf-wedge dr-w2-s3-poll-grace-5xx-and-named-refusal dr-w2-s4-scrub-knows-our-own-token dr-w2-s5-cli-status-stops-lying dr-w2-s6-engine-one-extractor-health-slow-vs-broken dr-w2-s7-scoped-search-permission-clamp; do bp task get $t -o json \| python3 -c "import sys,json;c=(json.load(sys.stdin).get('claim') or {});print('$t',c.get('worker'),c.get('expired_at'))"; done; date -u` |
| `dr-w2-s4-credential-redactor` (the id in the fence brief) DOES NOT EXIST; the real row is `dr-w2-s4-scrub-knows-our-own-token` | `bp task get dr-w2-s4-credential-redactor -o json` → `not_found`; `gh pr view 9731 --json body -q .body \| tail -1` → `Task: dr-w2-s4-scrub-knows-our-own-token` |
| dr charter tops out at **D36**; wave log has ONE wave (founding, 2026-08-05); the `W3` column entries are backlog rows, not a cut wave | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| grep -oE '^- \*\*D[0-9]+' \| tail -3` and `… \| sed -n '428,436p'` |
| dr **D31** cedes the console render path to cch (wave 33) and disclaims `deploy/**` as its own | `git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md \| sed -n '297,308p'` |
| cch **D379**'s "zero `dr-w2-*` slice tasks exist, so no builder is in flight" is now FALSE (18 exist) | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '653p'` vs the child census above |
| `cch-w34-s2` = PR **#9739**, MERGED and IS origin/main's tip → s5's "AFTER s2 MERGES" precondition is SATISFIED | `git show refs/tmp/9705:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '1621p'`; `gh pr view 9739 --json state,mergeCommit` |
| charter PR **#9705 is NO LONGER BLOCKED** — `PR references an active task` PASSES, mergeStateStatus CLEAN | `gh pr checks 9705 \| grep 'active task'` ; `gh pr view 9705 --json mergeable,mergeStateStatus` |
| the only dirty worktree touching `registry.ex` is dead scratch — its `truncated_from` candidate already shipped on main via #9687 | `git -C .claude/worktrees/wf_42ec8353-b47-22 diff --stat -- cloud/lib/barkpark_cloud/registry.ex`; `git show origin/main:cloud/lib/barkpark_cloud/registry.ex \| grep -n truncated_from` |
| stale open PR **#6028** (2026-07-23) still holds `cloud/priv/static/app.js` + cloud `router.ex` | `gh pr diff 6028 --name-only` |
