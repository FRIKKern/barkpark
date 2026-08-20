# v12 [pr-disposition-and-cheap-closables] — re-derivation recipes (2026-08-07 ~09:0xZ)

Wave 12, deploy-reliability epic. Verifier lane `v12-pr-disposition-and-cheap-closables`.
Every row is a literal command that re-derives one fact. origin/main at the time of
writing: `ba712a4b2`. Nothing here is quoted from the charter or a handoff.

## R1 — the 13 ledger files of #9976 + #10069, and their PATH absence on origin/main

```sh
gh pr view 9976  --json files -q '.files[].path'   # 6 paths, all tooling/grip/ledger/
gh pr view 10069 --json files -q '.files[].path'   # 7 paths, all tooling/grip/ledger/
git ls-tree -r --name-only origin/main tooling/grip/ledger/ | wc -l          # 603
for f in <the 13>; do git cat-file -e origin/main:tooling/grip/ledger/$f 2>/dev/null \
  && echo "PRESENT $f" || echo "ABSENT $f"; done                             # 13/13 ABSENT
```

## R2 — CONTENT absence (the test path absence cannot make): grep main for each file's
##      distinctive MEASUREMENT, not its filename

```sh
git grep -c -F -- "1032 failed / 1611 terminal" origin/main        # 0  (v10 quiet-host)
git grep -c -F -- "677 /  900 = 75.2%"          origin/main        # 0
git grep -c -F -- "task 96480 (90.3%), paper 9829 (9.2%)" origin/main  # 0 (v9 doc-type split)
git grep -c -F -- "1 of 106904 rows has no matching event" origin/main # 0
git grep -c -F -- "695 live journeys / 645 failed" origin/main     # 0  (w9 journey)
git grep -c -F -- "0.6% -> 26.1%"               origin/main        # 0
git grep -c -F -- "Site 1875/964/6 vs admin 1884" origin/main      # 0  (graph probe n30)
git grep -c -F -- "3 failed / 23 terminal = 13.0%" origin/main     # 0  (team-scoped)
git grep -c -F -- "pid 464677"                  origin/main        # 0  (graph-500 rss)
git grep -c -F -- "PR #9827 carries ZERO reviews" origin/main      # 0  (w8 stamp audit)
git grep -c -F -- "every hour AFTER is all-with_suffix" origin/main # 0 (graph-class-mem)
git grep -c -F -- "cloud/test/barkpark_cloud/deploy_ledger_test.exs:955" origin/main # 0
```
CAVEAT that keeps this honest — GENERIC infra strings DO hit, so a naive grep on the
wrong token manufactures a false PRESENT:
```sh
git grep -l -F -- "/etc/barkpark/agent.health.token" origin/main   # charter + 2 ledger rows
git grep -l -F -- "webhook_deliveries.event_id"      origin/main   # chat-tui charter + ssrf test
```
Grep the MEASUREMENT (a number that only this run produced), never the hostname/path.

## R3 — the TWO genuine partial-redundancies (the only content that survives elsewhere)

```sh
git grep -n -F -- "p50 0.329s" origin/main
# -> cloud/config/config.exs:247. The whole dr-w8-lifeline headline (p50 0.329s /
#    p99 5.771s / max 15.017s / 13,287 jobs / ZERO over 30s) is on main AS A CODE
#    COMMENT at config.exs:246-250. Its R1-R5 re-derivation COMMANDS are not.
git grep -n -F -- "31120806862" origin/main
# -> charter:3018, scripts/absent-context-census.sh:10, and 3 OTHER ledger rows.
#    merge-order-truth-wave8's central subject IS recorded elsewhere; its four
#    method gotchas are NOT (all four grep 0):
git grep -c -F -- "mergeStateStatus is computed lazily"        origin/main   # 0
git grep -c -F -- "SQUASH-merged"                              origin/main   # 0
git grep -c -F -- "Cancelled runs are concurrency-group kills" origin/main   # 0
git grep -c -F -- "case-arm echoes"                            origin/main   # 0
```

## R4 — the "p95 breakdown" is a METHOD, not numbers (correction to the wave brief)

```sh
grep -nE '[0-9]+ ?ms|p50=|p95=|p99=' <dr-w9-p95-what-is-actually-slow.md>   # ONE hit, line 1 (the title)
```
The file records ZERO measured percentiles. What it holds is the recipe plus two
mutation-proven errata that grep 0 on main:
```sh
git grep -c -F -- "socket-path requests land in the ring"        origin/main  # 0
git grep -c -F -- "long-lived SSE streams land as their lifetime" origin/main  # 0
```

## R5 — the CHARTER halves both PR bodies advertise are ALREADY on main

Neither PR's file list contains the charter (R1), though both bodies claim D107–D129 /
D130–D146. Enumerate what main really carries:
```sh
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md > /tmp/cm.md
for n in $(seq 100 180); do grep -q "\*\*D$n" /tmp/cm.md && printf "D$n "; done
# -> D100..D160 CONTIGUOUS present; D161..D180 ALL absent.
grep -n '\*\*D106' /tmp/cm.md   # line 136 — a CITATION, not a definition row
grep -c -F -- "9976" /tmp/cm.md; grep -c -F -- "10069" /tmp/cm.md   # 0, 0
```

## R6 — why the two PRs are open: NOTHING blocks them

```sh
for n in 9976 10069; do gh pr view $n --json state,mergeable,mergeStateStatus \
  -q '[.number,.state,.mergeable,.mergeStateStatus]|@tsv'; done   # OPEN MERGEABLE CLEAN, both
gh pr view 9976 --json statusCheckRollup \
  -q '.statusCheckRollup[]|select(.conclusion=="FAILURE")|.name'  # empty
gh pr view 9976 --json statusCheckRollup -q '.statusCheckRollup[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|[.name,.conclusion]|@tsv'
# all four SUCCESS on BOTH PRs.
```
NOTE: both carry a green `Re-land advisory (already-landed overlap)`. It compares
FILE PATHS only (`tooling/task-obsession/reland_check.py` docstring) — its pass is
NOT evidence of content novelty in either direction. Use R2, not this check.

## R7 — the one-criterion-short census (the briefed "nine" does not reproduce)

```sh
bp task get task-fb4fb869490b4213 -o json > /tmp/epic.json
python3 -c "
import json;d=json.load(open('/tmp/epic.json'))['children']
s=[c for c in d if c['lifecycle_status']=='open' and (c.get('criteria_progress') or {}).get('total',0)>0
   and c['criteria_progress']['total']-c['criteria_progress']['met']==1]
print(len(s))"                       # -> 43, not 9.  (11 of them are 0/1 backlog stubs.)
```

## R8 — 31 of the 43 have ONE unmet criterion and it is literally "MERGE-GATED"

```sh
bp task get <doc_id> -o json | python3 -c "
import json,sys
ac=json.load(sys.stdin)['doc']['content']['acceptance_criteria']
u=[x for x in ac if not x.get('met')]
print(u[0]['criterion'][:120])"
```
NOTE the criteria live at `doc.content.acceptance_criteria` — NOT at the top level and
NOT beside `criteria_progress`, which is the only criteria key the `children` summary
carries. A top-level read returns empty and reads as "no criteria".

## R9 — resolve each merge-gated row to its PR (github.issue is a MIRROR ISSUE, not the PR)

```sh
gh search prs --repo FRIKKern/barkpark "<doc_id>" --json number,state --limit 5
```
28 of 31 resolve to a MERGED PR. The three that do not:
- `dr-w8-s6-raw-capture-stops-leaking`  -> #10019 OPEN
- `dr-w10-s1-verdict-reads-the-deploy-rate` -> #10129 OPEN
- `dr-w11-s4-delivery-census-refuses`   -> #10192 OPEN

## R10 — the three open blockers, as they really are

```sh
for n in 10019 10129 10192; do gh pr view $n --json number,state,mergeable,mergeStateStatus \
  -q '[.number,.state,.mergeable,.mergeStateStatus]|@tsv'; done
# 10019 OPEN UNKNOWN UNKNOWN   (mergeStateStatus is LAZY — call twice, see merge-order-truth-wave8)
# 10129 OPEN CONFLICTING DIRTY
# 10192 OPEN MERGEABLE CLEAN
gh pr checks 10019 | grep -v skipping | grep fail
# Billing tier floor (rendered) / Console gate / Overflow guard (rendered) — all fail, since 02:18Z
gh pr checks 10192 | grep -viE 'skipping|	pass	'     # EMPTY — zero non-passing
gh pr view 10192 --json statusCheckRollup -q '.statusCheckRollup[]|select(.name=="Elixir gate" or .name=="Cloud gate" or .name=="Console gate" or .name=="PR references an active task")|[.name,.conclusion]|@tsv'
# all four SUCCESS. The digest's "TWO FAILING CHECKS" on #10192 is STALE.
```

## R11 — #10192's payload still not on main (so the s4 row is genuinely still gated)

```sh
git grep -c "def delivery" origin/main -- cloud/lib/barkpark_cloud/deploy_ledger.ex   # rc=1, ABSENT
```
