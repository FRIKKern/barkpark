<!-- doc-tier: cold | canonical-for: connectors-sweep-b-rerun-recipe | budget: 900tok -->
# Connectors done-set SWEEP B (provenance) re-derivation recipe — 2026-08-18

Independent rerun of SWEEP B over the live DONE set of epic `task-e640bb01fca6ea38`
(Barkpark Connectors). Verifier lane `sweep-b-rerun`. origin/main = e21bf409.

## Denominator (live L1)

    bp task get task-e640bb01fca6ea38 -o json > epic.json
    python3 -c 'import json,collections;d=json.load(open("epic.json"));\
    print(collections.Counter(c["lifecycle_status"] for c in d["children"]))'
    # Counter({done:109, cancelled:15, open:17, considering:16})  child_count=157

109 done, all doc_ids unique. child_count 157 is NOT the done count.
The 109th (pre-survey un-fetched) row = **connectors-wave-37-log** — it is the last
id in the children list (loop that stops on a missing trailing newline drops it).

## Fetch every done row, then recompute

    # write each done doc_id, then: bp task get <id> -o json > rows/<id>.json  (x109)
    # over rows/*.json content.acceptance_criteria + claim.closed_by:

- fabrication conjunction (null-claim AND met==0 AND all-evidence-empty AND boilerplate) = **0**
- met==0 set (total>0) = **0**
- met<total set = **{connectors-wave-35-log}** only (1/2)
- rows with ANY empty-evidence criterion = **1** (connectors-wave-35-log, criterion 2)
- rows with ZERO acceptance_criteria = **1** (connectors-wave-36-log — per-wave referent, documented close)
- closed_by histogram: None(null)=24, lead≈30, other-worker≈34, decide=17, review=4

## The two clean-looking edge rows are TRUE-DONE (do NOT reopen)

connectors-wave-35-log criterion 2 "charter PR merged to main" is marked met=false with
empty evidence, but the merge really landed:

    gh pr view 11953 --repo FRIKKern/barkpark --json state,mergeCommit  # MERGED 922c4e13...
    git merge-base --is-ancestor 922c4e13 origin/main && echo ANCESTOR   # ANCESTOR

connectors-wave-36-log has zero criteria but is a documented paperwork referent:

    gh pr view 12136 --repo FRIKKern/barkpark --json state  # MERGED 8dadc9b5...
    git cat-file -t b5dcd5d4af                              # commit (wave-log append)

## Verdict

SWEEP B provenance clean at 100%: zero fabrication shape, zero 0/N closes, all 24
null-claim rows full-met + fully evidenced (the OPPOSITE of the fabrication shape).
False-done count from the provenance dimension = **0**.
