# TLV unbuilt-partition recheck — merge-evidence join re-derivation (2026-08-18)

Wave: task-lifecycle-visibility reconciliation. Verifier lane: unbuilt-partition-recheck.
Local origin/main at verify time: `41b16d78db675abccde956954033e94c4a8de6b7`
(digest cited `d7da14e8fc` as origin/main; that SHA is an ANCESTOR of 41b16d78db —
tree only advanced, so this re-run supersedes the digest's gh-against-FRIKKern join).

## Re-derive the merge-evidence join for the 17 open ids

    # counts per id across ALL refs
    for id in <the 17 open ids + task-eal-bl-events-cold-index>; do
      git log --all --oneline --grep="$id" | wc -l
    done

Result: exactly 3 ids have hits; 14 open + 1 considering have ZERO hits on any ref.

| id | hits | verdict |
|---|---|---|
| ledger-merge-criterion-autostamp | 2 | GENUINE build |
| pds-bl-merge-gated-criteria-carry-the-flag | 2 | mention only, NOT a build |
| tlv-bl-js-vocab-generator | 2 | sibling+deferral, NOT a build |
| (other 14 open + 1 considering) | 0 | unbuilt |

Each hitting id = 1 squash-merge on origin/main (ancestor YES) + 1 pre-merge branch commit (ancestor NO).

## Confirm the three hits' nature

    git show -s --format='%s%n%b' 9e7132846f   # autostamp
    git show -s --format='%s%n%b' c86cc62fe1   # js-vocab hit
    git show -s --format='%s%n%b' d0910143c8   # pds-bl hit

- `9e7132846f` (#5742) — `Task: ledger-merge-criterion-autostamp` trailer; ancestor of origin/main = YES. THE build. STALE-OPEN, closeable by evidence.
- `c86cc62fe1` (#5707) — `Task: tlv-bl-js-vocab-drift-gate` (the DONE sibling). Body: "generating the TS is the deferred generator (tlv-bl-js-vocab-generator)." The ONLY commit naming the generator DEFERS it. Generator itself has no build.
- `d0910143c8` (#9527) — `Task: pds-w47-ledger-denominator-and-blind-spots`. The id appears only as a NAMED blind-spot row ("exactly one is open, pds-bl-…, parented to a different epic"). No trailer for it. No build.

## Autostamp close mechanics (0-based criterion gotcha)

    bp task show ledger-merge-criterion-autostamp -o json | .doc.content.acceptance_criteria

5 criteria (0..4). Only unmet = index **4**: met=false, merge_gate=true,
"PR merged to main (LEAD closes this criterion on merge)." Pay `--criterion 4`,
NEVER 5 (1-based slip pays the wrong/nonexistent index).

## Corroboration for the mis-parent lane

`pds-bl-merge-gated-criteria-carry-the-flag`.content.parent_id == `task-lifecycle-visibility-epic`
today, i.e. it physically lives under TLV but its SUBJECT is the PDS merge-gated class
(#9527 census names it as parented outside PDS's root). Re-parent target = PDS epic.
