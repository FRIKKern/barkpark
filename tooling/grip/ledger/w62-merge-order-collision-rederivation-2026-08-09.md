# W62 merge-order + collision scan — re-derivation recipes (2026-08-09)

Every row below is ONE literal command that re-derives the fact from scratch.
Scanned at `origin/main` = `839453b706`. Repo `FRIKKern/barkpark`.

## The contender on the wave's crown file

| Fact | Command |
|---|---|
| #10006 is the ONLY MERGEABLE open PR on `cloud/priv/static/app.js` | `gh pr list --state open --limit 300 --json number,mergeable,files --jq '.[] \| .number as $n \| .mergeable as $m \| .files[].path \| select(test("static/app\\.js$")) \| "\($n)\t\($m)"'` |
| #10006 touches exactly 3 files | `gh pr view 10006 --json files --jq '.files[].path'` |
| #10006 bumps NO shared counter (only 2 comment mentions) | `gh pr diff 10006 \| grep -nE 'scenarios\|census\|baseline\|@emitted_floor\|cssom' \| head -30` |
| #10006 is RED on `Console gate` because `tier-floor-render` failed | `gh run view --job 92748329198 --log-failed \| tail -30` |
| …and that failure is an ENVIRONMENT refusal (Chrome never started), not a defect | `gh run view --job 92748021002 --log-failed \| grep -i DevToolsActivePort` |
| #10006 is 2 ahead / 261 behind main | `gh api repos/FRIKKern/barkpark/compare/091e6648d2031a2697650a811ac1a12d6536b7ed...main --jq '{status:.status,ahead:.ahead_by,behind:.behind_by}'` |

## Shared-counter surfaces — all uncontested

| Fact | Command |
|---|---|
| `cssom-heads.baseline` is an EXACT authored-rule-head count of `app.css` | `git show origin/main:cloud/priv/static/__preview__/cssom-heads.baseline \| head -8` |
| `SCENARIO_RESIDUE` is the committed scenario literal the tier-floor sweep prints | `git show origin/main:cloud/priv/static/__preview__/breakpoint-sweep.mjs \| grep -n 'committed literal\|SCENARIO_RESIDUE'` |
| ZERO open PRs touch `__preview__/scenarios.mjs`, `breakpoint-sweep.mjs`, `cssom-heads.baseline` or `app.css` | `gh pr list --state open --limit 300 --json number,mergeable,files --jq '.[] \| .number as $n \| .files[].path \| select(test("__preview__/\|static/app\\.css$")) \| "\($n)\t\(.)"'` |
| there is NO global test-count floor in `__app.test.mjs` | `git show origin/main:cloud/priv/static/__app.test.mjs \| grep -nE 'tests\.length\|totalTests'` |

## The cuttability of `cch-w60-s7`

| Fact | Command |
|---|---|
| ZERO open PRs touch `verify_route_producer_exemption_test.exs` | `gh pr list --state open --limit 300 --json number,files --jq '.[] \| .number as $n \| .files[].path \| select(test("verify_route_producer_exemption")) \| "\($n)\t\(.)"'` |
| #11169 targets the OTHER census and is CONFLICTING | `gh pr view 11169 --json number,state,mergeable,mergeStateStatus,updatedAt,files` |

## The reader slice's router regions

| Fact | Command |
|---|---|
| `barkpark_json/4` at router.ex:9369, isu-6 block ends :9406 | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| sed -n '9369,9406p'` |
| `get "/v1/barkparks"` at :2037 | `git show origin/main:cloud/lib/barkpark_cloud/web/router.ex \| grep -n 'get "/v1/barkparks" do'` |
| #10154's only router hunk is @@ -1457,8 @@ | `gh pr diff 10154 \| awk '/^\+\+\+ b\/cloud\/lib\/barkpark_cloud\/web\/router.ex/{f=1;next} /^\+\+\+ /{f=0} f&&/^@@/{print}'` |
| #9956's router hunks top out at @@ -5268 @@ | `gh pr diff 9956 \| awk '/^\+\+\+ b\/cloud\/lib\/barkpark_cloud\/web\/router.ex/{f=1;next} /^\+\+\+ /{f=0} f&&/^@@/{print}'` |

## `__bpTestHook` insert distance (the one real textual adjacency)

| Fact | Command |
|---|---|
| 2FA exports (10006's insert point) at app.js:22690-22692 | `git show origin/main:cloud/priv/static/app.js \| grep -n 'accountTwoFactorBadgeHtml: accountTwoFactorBadgeHtml'` |
| rollback exports (s2's insert point) at :22379-22380, :22474 | `git show origin/main:cloud/priv/static/app.js \| grep -n 'rollbackRefusalTerminal: rollbackRefusalTerminal\|siteRollbackFailure: siteRollbackFailure'` |

## Roster (Law 0 baseline), live

| Fact | Command |
|---|---|
| 839 children — 416 open (incl. in_progress) / 344 done / 78 cancelled / 1 considering | `bp task get cloud-console-hardening-epic -o json \| python3 -c "import sys,json,collections;d=json.load(sys.stdin);print(d['child_count'],collections.Counter(x['lifecycle_status'] for x in d['children']))"` |
| every wave-62 candidate row is `executable` (no foreign claim) | same command, filter `execution_class` on the candidate `doc_id`s |
| `task-a0b92c5761233af4` has NO `criteria_progress` key → zero criteria | `bp task get cloud-console-hardening-epic -o json \| python3 -c "import sys,json;d=json.load(sys.stdin);print([x for x in d['children'] if x['doc_id']=='task-a0b92c5761233af4'])"` |

## Main's own console gates at 839453b706 — ALL GREEN

    gh api "repos/FRIKKern/barkpark/commits/839453b706/check-runs?per_page=100" --jq '.check_runs[]|"\(.name)\t\(.conclusion)"' | sort -u | grep -iE 'overflow|tier|cssom|console|cloud gate'
