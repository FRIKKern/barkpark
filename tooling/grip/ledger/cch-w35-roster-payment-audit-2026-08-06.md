# cch wave 35 — roster payment audit: re-derivation recipes

Written at VERIFY, 2026-08-06, against `origin/main` = `c73bbc07c`. Every row below is a
command a third party can re-run; nothing here is quoted from a charter D-row.

**Standing warning this file exists to carry:** charter `D370` already adjudicated four of
these rows as fully paid. All four are STILL OPEN today, several waves later, and the epic's
open count went 92 (D370's read) → 124 (this read). **Recording a free close in a D-row is
not paying it.** The payment is a `bp` write, executed at Decide and read back.

## R0 — the denominator (394 published, not 398)

    bp task get cloud-console-hardening-epic -o json > /tmp/r.json
    python3 -c "import json,collections;r=json.load(open('/tmp/r.json'));ch=r['children'];p=[c for c in ch if not c['doc_id'].startswith('drafts.')];print('all',len(ch),'published',len(p));print(collections.Counter(c['lifecycle_status'] for c in p))"

`children` is a TOP-LEVEL key beside `doc` — the strategize snippet's `d=d.get('doc',d)`
drops it and raises `KeyError: 'children'`. Expected: `all 398 published 394` /
`{'done': 235, 'open': 124, 'cancelled': 34, 'considering': 1}`. FOUR drafts, not three:
three open + one cancelled, which is exactly the 398/127/35 → 394/124/34 delta.

## R1 — cch-w12-s5 is a FULL free close (8/10 → 10/10)

    # c7, both charters carry the filing law:
    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '26,35p'
    git show origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md | sed -n '61,67p'
    # c10, PR #8500 merged:
    gh pr view 8500 --json state,mergedAt,mergeCommit

## R2 — cch-w28-s1 is a FULL free close (6/7 → 7/7)

    gh pr view 9356 --json state,mergedAt,mergeCommit   # MERGED 2026-08-03T14:53:51Z 0a1b4d2ea

## R3 — gr-backlog-css-check-missing-classes is a FULL free close (2/3 → 3/3)

    D=$(mktemp -d); git archive origin/main | tar -x -C $D
    cd $D/cloud/priv/static && node __css_check.mjs; echo "rc=$?"   # rc=0, "0 error(s)"

Run it from an `origin/main` ARCHIVE, never the primary checkout — the checkout is behind
`origin/main` and is what makes this row read open (D370 recorded the same trap).

## R4 — cch-w27-bl is a RETIRE, not a stamp (0/4, wholly subsumed)

    git show origin/main:cloud/lib/barkpark_cloud/failure_copy.ex | sed -n '546,547p'
    git merge-base --is-ancestor 9b4e76d5c origin/main; echo "rc=$?"   # rc=0

Payer `cch-w28-s5-refused-connection-is-not-a-timeout` is done 8/8, merged `9b4e76d5c`.
w27-bl's four criteria were never independently performed, so it CANCELS as superseded — a
`met:true` stamp on any of them would be a fabrication of work nobody did.

## R5 — cch-w11-s1 is NOT a free close (9/13 → 11/13, one unproducible, one half-built)

    gh api repos/:owner/:repo/branches/main/protection      # c10 PAID: 4 contexts, enforce_admins true
    git show origin/main:.github/required-checks.json       # committed spec == live protection
    gh pr view 8394 --json state,mergedAt,mergeCommit       # c13 PAID: dcd8c9ceff0e4505e5071ce8dbae7ee01aa0ac28
    gh pr view 8222 --json state,mergeStateStatus,mergedAt  # c11 DEAD: CLOSED / DIRTY / never merged
    H=$(gh pr view 9665 --json headRefOid -q .headRefOid)   # c12(a) PAID IN THE WILD
    gh api "repos/:owner/:repo/commits/$H/check-runs?per_page=100" -q '.check_runs[]|select(.name=="Console gate" or .name=="Cloud gate" or .name=="Elixir gate" or .name=="PR references an active task")|"\(.name) :: \(.conclusion)"'

c12(b) — the provoked illegitimate skip and `bp-merge.sh`'s refusal STRING — is genuinely
unbuilt. The row stays open.

**NUMBERING HAZARD:** `cch-w34-bl-amend-cch-w11-s1-criterion-10` numbers w11-s1's criteria
ONE LOWER than the live task does (it treats the "STEP 0" element as criterion 0). Its
"criterion 10" is the live array's **11th**; its "criterion 9" is the live **10th**; its
"criterion 12" is the live **13th**. A builder who follows that row literally amends the
PUT criterion and stamps the wrong two MET.

## R6 — cch-w30-s5-followup criterion 1 IS paid; criterion 2 is not

    git show origin/main:cloud/priv/static/app.js > /tmp/app.js
    grep -n "Check your connection and retry" /tmp/app.js   # 330, 9606, 12971 — every one a faultCopy( argument
    D=$(mktemp -d); git archive origin/main | tar -x -C $D
    cd $D/cloud/priv/static && node --test __app.test.mjs    # 873/873 pass on a FULL tree

The pin is `cch-w30-s5: no crash-path caller re-blames the input behind faultCopy's back`
(`__app.test.mjs:14056`), which reds if any of the three reverts to a bare sentence.
Archive the WHOLE repo: with only `cloud/priv/static` present, 15 census tests fail on
missing `cloud/lib` inputs and the run reads as 15 reds on main that are not there.
