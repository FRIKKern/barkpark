# felix-w31 reparent-readiness re-derivation

Verifier: felix-pristine wave 31. Confirms all 7 non-Felix riders are STILL
parent=task-96a908af98698118 (Felix) and open (none moved by a sibling), and that
`bp task move <id> cloud-console-hardening-epic` emits cleanly per row.

## Rerun

```
cd /Volumes/SATECHI/github/barkpark
bp task move --help 2>&1 | head -30
for id in gr-backlog-webhook-testsend-http-test gr-bl-tasks-route-parent-filter-ignored \
          gr-bl-close-time-audit-vacuous-green gr-bl-task-move-noop-help-drift \
          gr-bl-task-write-cap-breaks-briefs cch-w1-mirror-direct-write-unfenced \
          cch-w3-task-birth-attribution; do
  bp task get $id -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc') or d;print('$id parent=',doc.get('parent_id'),'life=',doc.get('lifecycle_status'))"
  bp task move $id cloud-console-hardening-epic --dry-run 2>&1 | head -6
done
bp task get cloud-console-hardening-epic -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc') or d;print('TARGET',doc.get('lifecycle_status'),doc.get('_type') or doc.get('type'))"
```

## Verdict (2026-08-18)

- All 7: parent=task-96a908af98698118, lifecycle=open, rail_rev=None (none already moved).
- dry-run emits `POST /v1/tasks/<id>/move {"new_parent_id":"cloud-console-hardening-epic"}` for each — clean.
- TARGET cloud-console-hardening-epic: lifecycle=open, type=task (id 7f3d49e6-c088-4461-a9e7-69544b424278) — valid destination.
- CAVEAT: `--dry-run` is a CLIENT-SIDE preview only ("server validate-only not available"),
  so the server-side `from_rail_rev` is NOT observable until the real move runs. Decide gets it
  from each move's response. No blocker — the rows are unmoved and open, so the real move is safe.
