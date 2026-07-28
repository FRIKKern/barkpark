# Re-derivation recipe — Cloud Console Hardening wave 6, Movement 0 second sweep (2026-07-28)

Verifier lane `movement0-second-sweep`. Run from repo root in the SHARED checkout.
Every command reads `origin/main` (or the live server), never a worktree.
Measured against `origin/main = a99127cade`; local HEAD `a8c767dbd`, tree CLEAN,
0 ahead / 1 behind.

## 1. Citation hardening — five cited SHAs are true first-parent merges

```sh
for s in 448749cf1 382f23540 26acc7a91 481d6f231 8c9c116c5; do
  git merge-base --is-ancestor $s origin/main && echo "$s ANCESTOR" || echo "$s NOT-ANCESTOR"
  git log --first-parent origin/main --oneline | grep -q "^${s:0:9}" \
    && echo "  first-parent: yes" || echo "  first-parent: NO (intermediate)"
  git show --stat --oneline $s | head -6
done
```

All 5: ANCESTOR + first-parent yes + subject and touched paths match the row they
are cited for. `git log -S` was NOT needed; the shas were already merge shas.

## 2. Content proofs for the ten Movement-0 candidates

```sh
git show origin/main:api/lib/barkpark/tasks/close.ex | grep -n 'check_close_holder'   # 319, 386, 395
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n 'on_conflict'     # 2635/2636 conflict_target [:team_id,:kind]
git show origin/main:cloud/priv/repo/migrations/20260719203000_unique_provider_per_team_kind.exs
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '540,560p'       # both oauth legs fenced
git show origin/main:api/lib/barkpark/content/mutations.ex | sed -n '430,447p'        # ensure_task_close_is_cas
git show origin/main:cloud/priv/static/__preview__/scenarios.mjs | grep -n 'account/sessions'  # 3014/3027/3035
git show origin/main:cloud/priv/static/__preview__/smoke.mjs | grep -n 'session-revoke'        # 538/548
git show origin/main:cloud/priv/static/app.js | grep -n 'OVERVIEW_FLEET'                       # 4905
git show origin/main:cloud/priv/static/__app.test.mjs | sed -n '302p'                          # "12 requests, not 40"
```

NOTE the arithmetic nuance: `gr-blk-console-refetch-storm` criterion 1 says "each of the
five endpoints once"; the landed fix + its pinning test deliver **12 requests, not 5**.
The defect (40) is gone; the criterion as WORDED is not literally met.

## 3. Checkout-wound rows — the wound is HEALED

```sh
git status --porcelain                                   # EMPTY
git diff origin/main -- cloud/priv/static/app.css | wc -l # 0
shasum -a 256 cloud/priv/static/app.css                  # a2c0cc890a25… == origin/main
grep -o '/\*' cloud/priv/static/app.css | wc -l          # 289
grep -o '\*/' cloud/priv/static/app.css | wc -l          # 289  (was 274 vs 275)
node cloud/priv/static/__css_check.mjs                   # 0 error(s)
node cloud/priv/static/__preview__/cssom-parity.mjs      # PARITY PASS, 1233/1233, MISSES 0, exit 0
```

D62's claim ("`__css_check` FAILS in the primary checkout") NO LONGER REPRODUCES.

## 4. `cch-bl-unpushed-base-branches` — content landed, refs untouched

```sh
for s in 82eb84a37 2bd8d6522 4876d2693 ba6b14d40; do
  git merge-base --is-ancestor $s origin/main; echo "$s -> $?"   # all 1 = NOT ancestor (squash chain)
done
git branch --list 'loop-epic/overview-stops-refetching-everything-sco-0' \
  'loop-epic/close-the-ledger-s-back-door-v1-data-mut-4' \
  'loop-epic/emit-mjs-write-stops-silently-deleting-h-3' \
  'loop-epic/the-console-stops-telling-every-user-the-1'   # all four present, all CHECKED OUT (+)
git ls-remote --heads origin 'refs/heads/loop-epic/…'      # EMPTY -> still unpushed
```

Heads still at the recorded SHAs (criterion 2 MET). All four contents landed on main
(criterion 0 MET). Criterion 1 (deliberate deletion) NOT done — a lead action, and the
`+` prefix means each ref is CHECKED OUT IN A WORKTREE, so a bare `git branch -d` fails.

## 5. Rows that REPRODUCE on origin/main (do NOT close)

```sh
# gr-bl-shootsh-scen-suggester-false-done — fixed-prefix grep, no shrinking probe, `|| true`
git show origin/main:cloud/priv/static/__preview__/shoot.sh | sed -n '148,156p'
# cch-bl-reland-check-backtick-trailer — sibling regex still backtick-blind
git grep -rn '\^\[\[:space:\]\]\*task:' origin/main -- .github scripts
#   -> reland-check.yml:52 (no backticks)  vs  scripts/pr-task-gate.sh:103 (`?…`? fixed)
# gr-bl-predicate-null-successor-silent-seal — bare interpolation survives
git show origin/main:cloud/priv/static/__preview__/seal-predicate.mjs | sed -n '126p;215p'
# gr-bl-seal-guard-port-and-stderr — PARTIAL: env override added, default still 4199
git show origin/main:cloud/priv/static/__preview__/overflow-guard.mjs | sed -n '84p'
# gr-bl-task-move-noop-help-drift — unconditional claim, in api/** (out of fence per D70)
git grep -n 'Emits a task.reparented' origin/main -- api/lib/barkpark/plugins/tasks.ex   # :945
# cch-bl-d34-wrapper-list-correction — charter still names 8 wrappers
grep -c 'require_team_admin\|require_primary_team_admin\|require_user_or_pat\|require_ability' \
  .claude/workflows/bp-cloud-console-hardening-charter.md   # 0
# cch-bl-get-census-rederive — NO committed re-runnable classifier exists
git ls-tree -r --name-only origin/main scripts tooling | grep -i census
```

## 6. `gr-bl-tasks-route-parent-filter-ignored` — REPRODUCES LIVE (L1)

```sh
TOK=<bp token>
curl -sf -G -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/tasks' \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' --data-urlencode 'limit=200' -o /tmp/f.json
curl -sf -G -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/tasks' \
  --data-urlencode 'limit=200' -o /tmp/u.json
python3 -c "
import json,collections
for t,p in (('FILTERED','/tmp/f.json'),('UNFILTERED','/tmp/u.json')):
    d=json.load(open(p)); rows=d['docs']
    par=collections.Counter(r.get('parent_id') or (r.get('content') or {}).get('parent_id') for r in rows)
    print(t,len(rows),'rows,',len(par),'parents',par.most_common(4))"
```

Both return **200 rows / 18 distinct parents with an IDENTICAL distribution**, and
ZERO rows carry `cloud-console-hardening-epic`. Standing law 4 confirmed at L1.
`tasks_controller.ex:280 maybe_filter_parent_id` serves the index's `parent=` slice,
a DIFFERENT parameter — it does not close this row.

## 7. Roster arithmetic (route A, standing law 4)

```sh
bp task get cloud-console-hardening-epic -o json > /tmp/epic.json
python3 -c "
import json,collections
d=json.load(open('/tmp/epic.json'))
ch=d['task']['children'] if 'task' in d else d['children']
print(len(ch), collections.Counter(c['lifecycle_status'] for c in ch))"
```

→ `129 Counter({'open': 82, 'done': 36, 'cancelled': 9, 'considering': 2})`.
Confirms the digest's 82/129; refutes the wish's 87/139 and the charter's 121/113.
