# Re-derivation recipe — Cloud Console Hardening wave 7, Movement 0 sweep (cch-* band + unbanded), 2026-07-28

Verifier lane `movement0-sweep-cch`. Scope: the 29 open/considering `cch-*` rows plus the
6 unbanded rows. The `gr-*` half is a sibling lane.
Every command reads `origin/main` (fetched, `f38c01920`) or the live server — never a worktree,
except §3 which is deliberately a working-tree measurement.
Shared checkout `/Volumes/SATECHI/github/barkpark`, tree CLEAN at measurement time.

## 0. Roster (standing law 4, route A)

```sh
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
python3 -c "
import json,collections
d=json.load(open('/tmp/epic.json'))
print(d['child_count'], collections.Counter(c['lifecycle_status'] for c in d['children']))"
```

→ `135 Counter({'open': 83, 'done': 41, 'cancelled': 9, 'considering': 2})`.
Wave 6's own ledger (`cch-w6-movement0-second-sweep-2026-07-28.md` §7) recorded `129 / 82 open`
earlier the SAME day: the roster GREW by 6 children / 1 open row between the two sweeps.
Any wave-7 arithmetic quoting 129 or 82 is already stale.

## 1. CLOSED BY CONTENT — three first-parent merge SHAs

```sh
for s in 576107987 448749cf1 16453cf65; do
  git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR"
  git log --first-parent origin/main --oneline | grep -E "^$s"
done
```

| row | SHA | PR |
|---|---|---|
| `cch-bl-overview-background-refresh-fails-silently` | `576107987` | #6541 (this epic's OWN wave-6 slice) |
| `cch-bl-close-fence-epoch-only` | `448749cf1` | #6420 |
| `task-04054d483ae95bd1` (async:true env-swap audit) | `16453cf65` | #5044 — **a SIBLING epic (Honest-Gates w1)** |

```sh
# overview background refresh
git show origin/main:cloud/priv/static/app.js | grep -n 'markRefreshStale\|refresh_failed'
#   5023:        if (!full) { markRefreshStale(); return; }
#   12603:    if (refreshStale) return "refresh_failed";

# close fence — worker identity IS now compared, by a separate gate
git show origin/main:api/lib/barkpark/tasks/close.ex | grep -n 'check_close_holder'   # 319, 386, 395
git show origin/main:api/test/barkpark/tasks/close_test.exs | grep -n 'not_holder'    # 1182, 1286, 1328
#   check_fencing/2 itself is UNCHANGED (still epoch-only, :377) — the criterion is met by the
#   D288 HOLDER GATE and its documented three allow-arms, not by widening check_fencing.

# 7 async:true modules
for f in billing_reconcile_isolation_test cloudflare_test github_test oauth_test vercel_test \
         web/router_test web/usage_route_test; do
  printf "%-40s " $f; git show origin/main:cloud/test/barkpark_cloud/$f.exs | grep -m1 -o 'async: *[a-z]*'
done          # all seven -> async: false
git show origin/main:cloud/test/barkpark_cloud/async_global_seam_guard_test.exs | grep -n 'no async: true'
```

## 2. LIVE — reproduces on origin/main (quote-ready one-liners)

```sh
git show origin/main:cloud/priv/static/__preview__/mock.js | sed -n '114p'
#   var res = mod.route(scen, method, path);        <- 3 args, no state bag
git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'account/sessions'
#   3125 / 3128 / 3141 / 3149  <- the stateful handlers ALREADY exist. The defect is the missing
#   4th argument at mock.js:114, NOT a missing revoke branch. `grep -c revoke mock.js` -> 0 is TRUE
#   and IRRELEVANT; a builder told "add revoke to mock.js" would fork the harness.

git show origin/main:.github/workflows/console-harness.yml | grep -n '415'   # :7 AND :83 (two sites)
node cloud/priv/static/__preview__/smoke.mjs; echo $?
#   FAIL fleet-support-provisioning — #instance-body unexpectedly has "data-step=\"secure\"" ; exit 1
git grep -n 'smoke.mjs' origin/main -- .github        # zero console hits (pdrender + search only)

git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | sed -n '92p'
#   const EPIC = 'task-47bc4168392dec17';

git show origin/main:cloud/priv/static/__css_check.mjs | grep -c 'ring-soft'   # 0
git show origin/main:design/check.mjs               | grep -c 'ring-soft'      # 0
git show origin/main:cloud/priv/static/app.css      | grep -c 'ring-soft'      # 33  (:77 /0.15, :116 /0.2)

git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8622,8628p'  # azure {:ok,_meta} DISCARDED
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '1081p'       # /#oauth=#{token}
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | sed -n '597,600p'      # bare update_all, no throttle
git show origin/main:cloud/lib/barkpark_cloud/accounts.ex | grep -n 'delete_all'   # 823/910/1980/2122 only
git show origin/main:.github/workflows/reland-check.yml | sed -n '52p'             # backtick-blind regex
git show origin/main:design/paper-editor-mirror.mjs | sed -n '275p'                # writeFileSync, unfenced
git show origin/main:scripts/docs-anchors-check.sh | grep -c '@boundary'           # 0
git show origin/main:cloud/priv/static/__css_check.mjs | sed -n '76,78p'           # names the cross-lang row as OUT
git show origin/main:cloud/priv/static/__preview__/smoke.mjs | sed -n '491,493p'   # the six DELETEs still uncovered
git grep -n 'RESIDUAL HARM' origin/main -- api/test                                # :551 still asserts the hole
git grep -n 'expected_ms\|expectedMs' origin/main -- cloud/lib                     # ZERO server-side estimates
```

### L1 — the Sobelow JOB is red on main while its RUN says success

```sh
gh run list --branch main --workflow security.yml -L 3 --json conclusion,databaseId
gh run view 30355776852 --json jobs -q '.jobs[] | "\(.name)\t\(.conclusion)"'
#   Sobelow static analysis (regression gate, baseline .sobelow-skips) (27.0, 1.18.1)   failure
#   ...while the RUN's conclusion is "success" (continue-on-error rollup).
```

## 3. Working-tree wound rows — NO LONGER REPRODUCE (three rows)

`cch-bl-appcss-orphan-comment-live`, `cch-bl-appcss-wound-owner`, `task-1e2b96c8907edef0`.

```sh
git status --porcelain                                       # EMPTY
git diff origin/main -- cloud/priv/static/app.css | wc -l    # 0
grep -o '/\*' cloud/priv/static/app.css | wc -l              # 290
grep -o '\*/' cloud/priv/static/app.css | wc -l              # 290   (filed as 274 vs 275)
node cloud/priv/static/__css_check.mjs                       # "0 error(s)", exit 0
```

CAVEAT, state it when closing: this is an L1 measurement of a WORKING TREE shared by many
sessions, not a commit. It closes as *no-longer-reproduces*, never as *fixed-by-<sha>*.

## 4. Branch protection — still absent (answers a wave-7 open question)

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection
#   {"message":"Branch not protected", "status":"404"}
```

So `cch-hg-register-cssom-required-check` and `pp-b-branch-protection` are both still unpaid, AND
no required-by-name pin can deadlock a `cloud/**`-only fence.

## 5. Unpushed base branches — content landed, refs still local AND checked out

```sh
git branch --list 'loop-epic/overview-stops-refetching-everything-sco-0' \
  'loop-epic/close-the-ledger-s-back-door-v1-data-mut-4' \
  'loop-epic/emit-mjs-write-stops-silently-deleting-h-3' \
  'loop-epic/the-console-stops-telling-every-user-the-1'    # all four, all "+" (checked out)
git ls-remote --heads origin 'refs/heads/loop-epic/…'       # EMPTY
```

The `+` prefix means a bare `git branch -d` fails — deletion needs the worktree removed first.
Lead action, zero builder spend.

## 6. `repo-pr-task-trailer-ownline` — root cause still ships

```sh
sed -n '850p' .claude/workflows/bp-epic-cycle.workflow.js
#   ... --body "<what it does + the gate you re-ran + Task: <task_id>>"   <- ONE-LINE body, mid-line trailer
git show origin/main:scripts/pr-task-gate.sh | sed -n '87,98p'   # extractor DOC now excludes mid-line
git show origin/main:scripts/pr-task-gate.sh | sed -n '133p'     # FAIL text still generic, no mid-line hint
```

Criterion 1 REPRODUCES; criterion 2 is half-paid (documented, not surfaced in the failure message).
