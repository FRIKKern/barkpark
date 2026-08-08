# anonymous-metering wave 1 — origin-side pins re-derived at verify time

Baseline: `origin/main` = `5b68852f46b75047908c1947280af1bf3f72e529` (after `git fetch origin`, 2026-08-08).

Every row below is a re-derivation recipe. Run the command; the fact is whatever it prints.

| Fact | Rerun |
|---|---|
| cloud Plug.Static `only:` allowlist is at **line 418** (survey's :350/:406 both wrong) | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'only: ~w'` |
| verbatim list: `only: ~w(index.html app.css app.js favicon.ico button.svg styleguide.html)` — no `robots.txt` | same as above |
| `cloud/priv/static/robots.txt` DOES NOT EXIST on main | `git show origin/main:cloud/priv/static/robots.txt` → `fatal: path ... does not exist` |
| `api/priv/static/robots.txt` EXISTS and is the stock Phoenix stub (every directive commented out) | `git show origin/main:api/priv/static/robots.txt` |
| api needs NO allowlist edit: `robots.txt` is already in `static_paths/0` | `git show origin/main:api/lib/barkpark_web.ex \| sed -n 7p` |
| static_allowlist_test pins 200 for 5 paths / 404 for `__preview__` ×4 / 404 for a fixture / `/v1` fallthrough — nothing about robots | `git show origin/main:cloud/test/web/static_allowlist_test.exs` |
| cch charter last D-row = **D616**; no branch of the freshest 60 carries D617+ | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| grep -oE '^\| D[0-9]+' \| sed 's/\| D//' \| sort -n \| tail -1` |
| cch D-number gaps: 95, 499-510, 535-546, 562-574 | `... \| sort -n \| awk 'NR>1 && $1!=prev+1 {print prev"->"$1} {prev=$1}'` |
| cch fence header is `## Surface fence` (line 123): **In fence:** `cloud/`, `api/lib/barkpark_web/live/` | `git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \| sed -n '123,126p'` |
| widening idiom = a named `Wave-N widening` block under §Surface fence + a D-row pointing at it (D377 does exactly this) | `... \| grep -nE '^\| D377 '` |
| D397 precedent for editing a FOREIGN charter by line number: "fix ... `.claude/workflows/bp-search-template-charter.md:103`" | `... \| grep -nE '^\| D397 '` |
| anon charter D6 = charter lines 79-84; it names NO wording for the "three prepared templates" | `git show origin/main:.claude/workflows/bp-anonymous-metering-charter.md \| sed -n '79,84p'` |
| anon roadmap slice 2 Surface column is bare `api/** + cloud/**` (charter line 123) — no cloud-router allowlist named | `git show origin/main:.claude/workflows/bp-anonymous-metering-charter.md \| sed -n '119,131p'` |
| flat anonymous `/papers/:slug/source` + `/papers/:slug/email` exist under `:public_root` | `git show origin/main:api/lib/barkpark/plugins/bulldocs.ex \| sed -n '190,212p'` |
| the 4-key pin is at `request_stats_controller_test.exs:41-42` AND the test NAME at `:31` restates the contract | `git show origin/main:api/test/barkpark_web/controllers/request_stats_controller_test.exs \| sed -n '31p;41,42p'` |
| `task-8e9cac2018a7fe1c` (anon-metering epic) has `child_count: 0` | `bp task get task-8e9cac2018a7fe1c -o json` |
| `dr-bl-w9-request-stats-behaviours-are-untested` open, claim null, 0/5 | `bp task get dr-bl-w9-request-stats-behaviours-are-untested -o json` |
| `dr-w5-s2-beat-carries-load15-and-5xx` open, claim lapsed (epoch 7, expired 2026-08-06), 8/10 | `bp task get dr-w5-s2-beat-carries-load15-and-5xx -o json` |
| `dr-w6-s1-land-the-stack` open, claim lapsed (epoch 10, expired 2026-08-07), 6/7 | `bp task get dr-w6-s1-land-the-stack -o json` |
| PR #9888 MERGED 2026-08-07T00:50:57Z, merge commit `dfa5e4dac8fa9fd9644ad8cbe2dce0c4eefe66a4` — so both dr rows' merge gates are satisfiable today | `gh pr view 9888 --json state,mergedAt,mergeCommit` |
