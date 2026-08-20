# Scaffy W8 — ledger-closeout re-derivation recipes (2026-08-17)

Verifier: ledger-closeout lane. All commands re-run from repo root against origin/main (fetched 2026-08-17). No repo mutations, no bp writes.

## (a) 8 currency-sweep rows — all done, all criteria met:true, evidence non-empty

The sweep task `scaffy-backlog-ledger-currency-sweep` (open 0/3) names 8 rows. Re-derive their current state:

```
for t in scaffy-backlog-classify-append-redesign scaffy-backlog-w2-validator \
  scaffy-w2-corpus-conformance scaffy-backlog-repo-aware-validate \
  scaffy-backlog-discover-go-pass scaffy-backlog-usage-noun-drift-fix \
  scaffy-backlog-catalog-first-doctrine scaffy-w7-corpus-prose; do
  bp task get "$t" -o json | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];c=d["content"];print(d["doc_id"],d["lifecycle_status"],[ (a["met"],len(a.get("evidence") or "")) for a in c["acceptance_criteria"]])'
done
```

All 8 already reconciled (each criterion met:true, evidence >= 50 chars, no empty/vague strings). The sweep's OWN description was authored pre-reconciliation (it says classify-append c3 is met:false pointing at unmerged 6162ea58d) — that is STALE: the row now shows c3 met:true citing #4007/4e82b914d. Sweep task is close-by-evidence.

Cited merge SHAs, all proven ancestors of origin/main with matching subjects:

```
for sha in 4e82b914d d7fb96ec8 f5efa0228 ca938f4a2 f8abeca1d e4c48f9f3 6b730a898 2fd3e8419 fad51a7de; do
  git merge-base --is-ancestor $sha origin/main && echo "ON-MAIN $sha $(git log -1 --format=%s $sha)"; done
```

Row -> merge SHA: classify-append=#4007/4e82b914d; w2-validator=#3658/d7fb96ec8 (+#3663 f5efa0228, +#3664 fixpoint); w2-corpus-conformance=#3664/ca938f4a2; repo-aware-validate=#3754/f8abeca1d; discover-go-pass=#3986/e4c48f9f3; usage-noun-drift-fix=#3973/6b730a898; catalog-first-doctrine=#3987/2fd3e8419; w7-corpus-prose=#3964/fad51a7de.

## (b) two orphaned branches — both SAFE TO PRUNE, no unique wanted content

Neither is an ancestor of origin/main; each has exactly one unmerged commit (`git cherry` prints `- <sha>`). Their OWN contribution is the 3-dot diff (two-dot tip diff is 256KB of pure stale-base noise — main advanced ~5,500 commits since 2026-07-17; ignore it).

Branch 1 `loop-epic/w7-prose-truth-add-block-type-classify-b-1` (20ef00eec): 3-dot diff = add-block-type.scaffy + classify-block-type.scaffy + papers.md. Content is (i) the w7 corpus-prose work — all four themes live on main via #3964: `git show origin/main:scaffy/commands/add-block-type.scaffy | grep -c "DRY-RUN HONESTY"` =1, `"Composition tier (MANDATORY"` =1, classify `"PAIRING LAW"` =2, papers.md `"no single-paper GET"` =1; PLUS (ii) the OLD classify-v2 "self-consuming REPLACE" (D58) command body, superseded by v3 append design on main (#4007). Branch-unique lines are obsolete v2 phrasings + an older papers.md "Authoring standard" draft. LABEL CORRECTION for Decide: the stale-branches task calls this "a superseded classify-v2 attempt - real work shipped as #4007" — accurate but incomplete: it ALSO carries w7 prose superseded by #3964. Prune verdict unchanged.

Branch 2 `loop-epic/add-block-type-v2-flagship-gains-its-pd--5` (6d60fa27c): 3-dot diff = add-block-type.scaffy only. Branch = 418 lines, main = 789 lines. Branch is an OLDER v2 flagship draft carrying the WRONG "Composition tier (conditional)... a leaf block needs nothing" doctrine — the exact doctrine #3964 corrected to MANDATORY. Main is a strict superset. 33 branch-unique lines, all obsolete. Prune-safe.

```
for BR in origin/loop-epic/w7-prose-truth-add-block-type-classify-b-1 origin/loop-epic/add-block-type-v2-flagship-gains-its-pd--5; do
  git merge-base --is-ancestor $BR origin/main || echo "$BR NOT-MERGED"; git cherry origin/main $BR; done
```

## (c) bp-scaffy-epic children — 80 total: 71 done, 1 cancelled, 5 open, 3 considering

```
bp task get bp-scaffy-epic -o json | python3 -c 'import json,sys;d=json.load(sys.stdin);ks=d["children"];from collections import Counter;print(Counter(k["lifecycle_status"] for k in ks));[print(k["lifecycle_status"],k["doc_id"]) for k in ks if k["lifecycle_status"] in ("open","considering")]'
```

OPEN(5): scaffy-backlog-file-flag-sweep, scaffy-backlog-api-v1-9-budget-ratchet, scaffy-backlog-blocks-editable-studio, scaffy-backlog-ledger-currency-sweep, scaffy-backlog-stale-addblocktype-branches.
CONSIDERING(3): scaffy-backlog-composition-primitive, scaffy-backlog-value-capture-primitive, **pbw-backlog-scaffy-deep-recipes**.

SURVEY GAP: `pbw-backlog-scaffy-deep-recipes` (considering, parent=bp-scaffy-epic, "DISCOVERED NOT THIS WAVE" — scaffy recipes for expensive block layers: Studio lockstep, SDK builders, hydration) is the third considering child the survey's stated considering set (D55 composition + value-capture primitives) did NOT enumerate. It carries a `pbw-` prefix (PD block-wishlist origin) but hangs under the scaffy epic.
