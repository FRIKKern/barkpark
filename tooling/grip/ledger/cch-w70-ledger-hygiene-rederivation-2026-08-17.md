<!-- doc-tier: cold | canonical-for: cch-w70-ledger-hygiene-rederivation | budget: 1200tok -->
# cch-w70 ledger-hygiene re-derivation (verifier, 2026-08-17)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-derive the ledger state Decide files against for wave 70. All rows read at d020382.

## Spine + candidate rows — status/claim/parent (all OPEN, UNCLAIMED unless noted)

```
for s in \
  cch-w67-bl-rollback-refusal-discards-the-box-s-own-words \
  cch-w67-followup-delete-site-typed-fk-failure \
  cch-w62-bl-friendly-throws-on-the-nested-envelope-it-is-handed \
  cch-w62-bl-the-site-plane-relays-prose-where-it-measured-a-typed-code \
  cch-w67-bl-the-cli-site-delete-receipt-flattens-every-typed-refusal \
  cch-w69-bl-audit-table-prose-repoint-after-app-js \
  cch-w69-bl-worker-route-stores-url-unnormalised \
  cch-w69-bl-site-create-detail-is-cli-voiced-console-string-matches-to-strip-it \
  cch-w53-bl-twofa-rows-render-as-raw-slugs \
  cch-w30-s5-followup-vague-fallbacks \
  cch-w34-bl-bare-friendly-renders-billing-copy-on-four-reads \
  cch-w68-bl-smoke-rollback-fixture-shape-pin \
  cch-w68-s4a-followup-manifest-prunes-orphan-slots ; do
  bp task get "$s" -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];c=d.get("claim");print(d["lifecycle_status"],(c or {}).get("worker"),d.get("parent_id"))'
done
```

Findings:
- All 8 spine/spine-candidate rows OPEN, claim=None, parent=cloud-console-hardening-epic. No foreign claim.
- cch-w67-bl-the-cli-site-delete-receipt-flattens-every-typed-refusal: OPEN, claim=None, assignee=epic-builder-… epoch=6 — PR #11784 is MERGED; this is a merge-gated close the lead owes, not live work.
- cch-w53-bl-action-labels-has-no-twofa-entry: lifecycle=CANCELLED by decide-cch-w69 (the D851 twofa duplicate; ownership of the twofa fill is single → cch-w53-bl-twofa-rows-render-as-raw-slugs).

## Instruments epic parent EXISTS

```
bp task get cch-instruments-epic -o json | python3 -c 'import sys,json;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"],d["title"],d["child_count"])'
# open  EPIC: Cloud Console INSTRUMENTS …  252
```
The two w68 residual rows to re-home (currently parent=cloud-console-hardening-epic):
- cch-w68-bl-smoke-rollback-fixture-shape-pin  (GH #11713 open)
- cch-w68-s4a-followup-manifest-prunes-orphan-slots  (GH #11692 open)

## D836 packet link-back

`gh issue view 11547` → OPEN, "Any team member can permanently destroy a site, while only a team admin can destroy an instance — the tiers differ and nothing states why". This is the product-ruling issue; packet files/refines against it, never builds the tier raise.

## Concurrent-dup scan — CLEAN

`gh pr list --state open --limit 40 --json number,title,headRefName` — no open PR headRef or title references any spine slug (rollback-refusal, followup-delete-site, friendly, audit-table, worker-route, site-create-detail, twofa). No dup-launch risk.
