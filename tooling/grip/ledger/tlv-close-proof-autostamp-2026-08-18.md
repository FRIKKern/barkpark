# Re-derivation: ledger-merge-criterion-autostamp is safe to close at 0-based --criterion 4

Wave: task-lifecycle-visibility reconciliation (2026-08-18). Verifier lane close-proof-autostamp.

## Claim
`ledger-merge-criterion-autostamp` (parent task-lifecycle-visibility-epic) is a STALE-OPEN
close-candidate: shipped by PR #5742, sole unmet criterion is the 0-based index-4 merge-gate row.

## Re-run recipes

Ancestor + trailer (PR built it, on main):
```
git merge-base --is-ancestor 9e7132846f origin/main && echo YES
git show -s --format='%s%n%b' 9e7132846f | grep '^Task:'
# -> feat(tasks): merge events auto-stamp... (#5742);  Task: ledger-merge-criterion-autostamp
gh pr view 5742 --repo FRIKKern/barkpark --json state,mergeCommit
# -> {"state":"MERGED","mergeCommit":{"oid":"9e7132846f9c73e06855c49dc5bfc89ee3ff0c48"}}
```

Criterion split (which index is unmet, is it the merge_gate row):
```
bp task get ledger-merge-criterion-autostamp -o json | \
  python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"]["content"]["acceptance_criteria"];[print(i,c["met"],c.get("merge_gate"),c["criterion"][:40]) for i,c in enumerate(d)]'
# -> 0 True None / 1 True None / 2 True None / 3 True None / 4 False True "PR merged to main..."
```
criteria_progress = met 4 / total 5. Index 4 (0-based) is the SOLE unmet criterion AND the only
merge_gate:true row. Pay `--criterion 4`, never 5 (1-based slip pays a met neighbour).

## Close mechanics (claim.worker=None, epoch=8, expired 2026-07-22)
Claim is LAPSED (worker=null, expired_at past). Re-claim by id first (bumps epoch 8 -> new),
then close on the fresh holder+epoch. Do NOT close on epoch 8 (no live holder).

Exact command the lead runs one phase later (0-based index 4, exact stored criterion text
incl. trailing period):
```
bp task claim ledger-merge-criterion-autostamp <worker>          # returns new epoch
bp task close ledger-merge-criterion-autostamp <worker> <epoch> done \
  "shipped by PR #5742 (9e7132846f), merge-gate autostamp event bridge on origin/main" \
  --set 'criteria:=[{"index":4,"met":true,"criterion":"PR merged to main (LEAD closes this criterion on merge).","evidence":"PR #5742 merged 9e7132846f9c73e06855c49dc5bfc89ee3ff0c48; ancestor of origin/main; Task: trailer = ledger-merge-criterion-autostamp"}]'
```
`criterion` text is REQUIRED and must match the stored row at index 4 exactly, else 409
criteria_mismatch / criterion_text_required. My local origin/main = 41b16d78db (survey saw
d7da14e8fc; both carry 9e7132846f as ancestor — YES holds regardless of head drift).
