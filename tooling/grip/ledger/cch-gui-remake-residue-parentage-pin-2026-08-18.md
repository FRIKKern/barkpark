<!-- doc-tier: cold | canonical-for: cch-gui-remake-residue-parentage-pin-recheck | budget: 400tok -->

# Residue-parentage pin — Cloud GUI remake reconcile wave (2026-08-18)

> HISTORICAL RECORD (2026-08-18) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Re-derivation recipe for the four named residue items of epic task-47bc4168392dec17.
A true residue number rests on these four being OPEN and correctly homed to LIVE
owners. billing-live-gate is parented to the GOAL (not the epic) so it is invisible
to any epic-children census — it MUST be checked by id or it silently vanishes.

## Re-run

```bash
cd /Volumes/SATECHI/github/barkpark
for t in gr-ops-platform-admin-emails cloud-console-billing-live-gate \
         gr-backlog-qr-live-scan-proof gr-backlog-console-redaction-allowlist; do
  echo "== $t =="
  bp task get $t -o json | python3 -c \
    "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['parent_id'])"
done
```

## Expected (verified 2026-08-18)

| item | lifecycle | parent_id | parent owner status |
|---|---|---|---|
| gr-ops-platform-admin-emails | open | cloud-console-hardening-epic | open (live) |
| cloud-console-billing-live-gate | open | cloud-console-goal | done goal (deliberate — see note) |
| gr-backlog-qr-live-scan-proof | open | cloud-console-hardening-epic | open (live) |
| gr-backlog-console-redaction-allowlist | open | cloud-console-hardening-epic | open (live) |

## Note

cloud-console-goal reads lifecycle=done, yet billing-live-gate (open) is deliberately
homed to it, not to any epic — this is by design (a permanent live-prod gate parked on
the goal, invisible to epic-scoped rosters). A done PARENT does not close an open CHILD.
The pin holds: all four items open, none orphaned, all homed exactly where the direction
predicts. No re-parent action required.
