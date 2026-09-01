<!-- doc-tier: cold | canonical-for: half-taken-close-repair-recipe | budget: 600tok -->

# Half-taken close repair verb (pe-w2-bpml-inline-vocabulary, 2026-08-17)

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

## Anomaly

A slice can land in a state where **the claim slot is closed but lifecycle_status is still `open`**:
the lead-loop closed the claim (epoch 7, closed_by=lead-loop, closed_at 13:45:35Z) yet
`lifecycle_status` never advanced. A done slice sitting open poisons every both-directions
ledger audit the epic runs.

## The working verb — plain `bp task close`, re-run on the SAME claim

`bp task close <id> <worker> <epoch>` is the fix. It is **idempotent on the claim CAS** — passing the
worker+epoch of the already-closed claim is accepted (not refused), and the call flips
`lifecycle_status` open -> done as a side effect. No doc-patch fallback is required.

```
bp task close pe-w2-bpml-inline-vocabulary lead-loop 7
# -> exit 0
# pe-w2-bpml-inline-vocabulary epoch=7 rev=c16b26a60598ea698c963e1defa08542
```

Re-read the PUBLISHED ledger to confirm:

```
bp task get pe-w2-bpml-inline-vocabulary -o json \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);doc=d.get("doc",d);print(doc.get("lifecycle_status"),doc.get("claim"))'
# BEFORE: open  {... closed_at 2026-08-17T13:45:35Z, epoch 7, worker lead-loop ...}
# AFTER : done  {... closed_at 2026-08-17T15:05:50Z, epoch 7, worker lead-loop ...}
```

The tell that it worked: `closed_at` is refreshed to the repair timestamp while `epoch` and
`worker` stay 7 / lead-loop, and `lifecycle_status` reads `done`.

## Recipe for every future half-taken close

1. `bp task get <id>` — confirm lifecycle=open AND claim.closed_at is set (that is the half-taken shape).
2. `bp task close <id> <claim.worker> <claim.epoch>` — use the EXISTING claim's worker+epoch, not a new one.
3. Re-read the published doc; confirm lifecycle=done.
4. The doc-patch fallback (`bp doc patch task <id> --set lifecycle_status=done && bp doc publish`) was
   the anticipated escape hatch but was NOT needed here — reach for it only if step 2 returns a CAS refusal.

## Note

`acceptance_criteria` read back as `null` on this doc (the "5/5 met" lived in the wave narrative,
not in a stored acceptance_criteria array). Repairing lifecycle does not depend on criteria being present.
