<!-- doc-tier: cold | canonical-for: pe-w8-disposition-census-rederivation | budget: 900tok -->

# PE wave-8 disposition census — re-derivation recipe (2026-08-17)

Fresh per-id census of every non-terminal Paper Excellence task at wave-8 verify time.
Confirms the survey/digest prediction byte-for-byte and pins the seal-time worksheet.

## Result of record

Epic `task-4792223ca9eb5a7d` child walk: **48 children = 36 done + 5 cancelled + 7 open**.
The 7 open children are EXACTLY the predicted set (nothing changed vs digest):

| id | met/total | disposition bucket |
|---|---|---|
| pe-w2-bl-device3-display-scale | 0/6 | D52 crown brief — kept under epic, re-file to root at seal |
| pe-bl-framed-finale-authoring | 0/4 | D52 crown brief — kept under epic, re-file to root at seal |
| pe-bl-css-bundle-freshness-gate | 0/2 | D52 crown brief — kept under epic, re-file to root at seal |
| pe-bl-cold-agent-run | 0/5 | this-wave slice (the run itself) |
| pe-w6-bp-paper-new | 4/5 | merge-gated on #11934; 5th crit rides the merged binary |
| pe-w7-epic-seal | 0/3 | this-wave slice |
| pe-w7-hg-anthropic-key | 0/1 | this-wave slice (human gate) |

Root-level strays already correctly re-filed by pe-w7-ledger-disposition (do NOT block seal):
26 Bucket-B backlog children re-parented to root (all parent=None, verified 5-of-26 landed)
plus `pe-w3-wave-lead-ops` (open 2/6, parent=None — recorded split, honest MISS notes).

The four pe-w7 done-closes carry VERBATIM-TEXT evidence stamps, zero `criteria_override`
on any — chain of custody is clean for the seal to cite.

## Re-derive

    # 1. epic child walk + open bucket
    bp task get task-4792223ca9eb5a7d -o json | python3 -c 'import sys,json;d=json.load(sys.stdin);ch=d["children"];from collections import Counter;print(Counter(x["lifecycle_status"] for x in ch));[print(x["doc_id"],x["criteria_progress"]) for x in ch if x["lifecycle_status"] not in ("done","cancelled")]'

    # 2. per-id confirm each open child (parent + lifecycle)
    for id in pe-w2-bl-device3-display-scale pe-bl-framed-finale-authoring pe-bl-css-bundle-freshness-gate pe-bl-cold-agent-run pe-w6-bp-paper-new pe-w7-epic-seal pe-w7-hg-anthropic-key; do bp task get $id -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];print("'"$id"'",d.get("parent_id"),d.get("criteria_progress"))'; done

    # 3. prove pe-w7 closes are verbatim-evidence, not override
    for id in pe-w7-fix-11934-regression pe-w7-rubric-freeze pe-w7-cold-harness pe-w7-ledger-disposition; do bp task get $id -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];c=d.get("content",d);print("'"$id"'","override=",c.get("criteria_override"));[print("  met=%s ev:%s"%(a["met"],a["evidence"][:80])) for a in c.get("acceptance_criteria",[])]'; done

    # 4. spot-verify the 26 re-parents landed (sample)
    for id in pe-bl-asciicast-selfhost pe-w1-bundle-table-scroll-chrome-gap task-0098ba55d2642545; do bp task get $id -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];print("'"$id"'","parent=",d.get("parent_id"))'; done
