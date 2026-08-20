# bp close-gate drill — re-derivation recipe (2026-07-28)

Gates shipped in `448749cf1` (PR #6420, PDS-D288/D289/D290). Drilled live against
`https://guerrilla.barkpark.cloud` with throwaway draft tasks. Every step below is
replayable; each creates its own throwaway, so nothing on the real ledger is touched.

## Setup

```bash
bp task create --set title='THROWAWAY holder-gate drill (delete me)' \
  --set lifecycle_status=open \
  --set 'acceptance_criteria:=[{"criterion":"drill criterion alpha","met":false},{"criterion":"drill criterion beta","met":false}]' \
  --yes -o json          # -> {"id":"task-XXXX", ...}
bp task claim task-XXXX worker-alpha -o json   # note claim.epoch (E)
```

## 1. Holder gate applies only when a claim EXISTS

```bash
bp task close task-XXXX worker-beta E -o json
# 409 not_holder:worker-alpha
```

But an UNCLAIMED task closes with any worker id, no override:

```bash
bp task create --set title='THROWAWAY unclaimed (delete me)' --set lifecycle_status=open --yes -o json
bp task close task-YYYY any-worker 0 done "drill" -o json   # -> ok:true
```

`close.ex` holder arm #1 is "no claim map -> allowed" (container closes).

## 2. holder_override lands and is recorded durably

```bash
bp task close task-XXXX worker-beta E cancelled "drill" --set holder_override='reason' -o json
bp task get task-XXXX -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['doc']['content']['close_override'])"
# {'holder': {'actor':'worker-beta','held_by':'worker-alpha','reason':'reason','ts':'...'}}
```

## 3. Criteria gate is INDEPENDENT of the holder gate and applies to unclaimed closes too

```bash
bp task close task-XXXX worker-alpha E done "drill" -o json               # 409 criteria_unmet:0,1
bp task close task-XXXX worker-alpha E done "drill" \
  --set 'criteria:=[{"index":0,"met":true,"evidence":"x","criterion":"drill criterion alpha"},{"index":1,"met":true,"evidence":"x","criterion":"drill criterion beta"}]' -o json
# STILL 409 criteria_unmet:0,1 — same-command flips do not count
bp task close task-XXXX worker-beta E done "drill" --set holder_override='r' -o json
# STILL 409 criteria_unmet — holder_override does NOT satisfy the criteria gate
bp task close task-ZZZZ lead 0 done "drill" --set criteria_override='why' -o json   # ok:true
# close_override.criteria = {actor, reason, ts, unmet:[{index,criterion}]}; met stays false
```

## 4. cancelled / blocked are exempt BY NAME

```bash
bp task close task-XXXX worker-beta E cancelled "drill" --set holder_override='r' -o json  # ok
bp task close task-WWWW lead 0 blocked "drill" -o json                                     # ok, criteria unmet
```

## 5. Sentinel worker ids die before the DB

```bash
bp task close task-YYYY None 0 done "drill" -o json   # 409 sentinel_worker_id:None
bp task close task-YYYY "  "  0 done "drill" -o json  # 409 sentinel_worker_id:
```

## 6. `bp task stamp` HAS a holder gate and NO override

```bash
bp task stamp task-XXXX worker-beta E --criterion 0 --met --evidence x --criterion-text "drill criterion alpha" -o json
# 409 not_holder   (bare message, no remedy text)
bp task stamp ... --set holder_override='r'
# usage: unknown flag --set for task stamp   <- there is no escape hatch
bp task stamp task-YYYY lead 0 --criterion 0 --met ... -o json
# 409 not_in_progress:open   <- an UNCLAIMED task cannot be stamped either
```

Consequence: the criteria refusal tells you to "stamp them as you prove them", but on an
unclaimed or foreign row stamping is impossible. The only honest cheap path is
**claim it yourself -> stamp -> close as holder** (zero overrides), proven:

```bash
bp task claim task-YYYY lead -o json           # epoch E2 (fresh claim epoch is 1, not 2)
bp task stamp task-YYYY lead E2 --criterion 0 --met --evidence "proof" --criterion-text "<verbatim>" -o json  # ok
bp task close task-YYYY lead E2 done "drill" -o json                                                          # ok
```

## 7. HTTP status of the refusals

```bash
TOK=$(python3 -c "import json;print(json.load(open('$HOME/.config/barkpark/config.json'))['token'])")
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://guerrilla.barkpark.cloud/v1/tasks/task-XXXX/close \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"worker_id":"worker-beta","observed_epoch":1,"lifecycle_status":"done"}'
# 409
```

## 8. The manifest lie

```bash
git show origin/main:api/lib/barkpark/plugins/tasks.ex | sed -n '774p'
bp task close --help | grep 'never block a close'
```

Both still say "Unmet criteria never block a close (soft warning only)" — false since
`448749cf1`. `docs/setup/TASK-SYSTEM.md:188` is already correct; the manifest is the
only stale copy, and it is what every agent reads.

## Throwaway tasks created by this drill (drafts, never published)

task-5dd222f868c5c282 (done) · task-f48a7e3d4c1efb9b (cancelled) ·
task-0ebf94028a2aaa4e (done) · task-bb2835e35434dd8f (blocked) ·
task-e4465e1900d34637 (done) · task-31acb3f3044d2695 (cancelled)
