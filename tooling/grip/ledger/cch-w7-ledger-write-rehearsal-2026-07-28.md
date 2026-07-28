# cch-w7 — ledger-write rehearsal (Movement 0 pre-flight)

Rehearsed live on guerrilla 2026-07-28 against scratch rows only (all created,
exercised, cancelled and deleted; epic roster re-read unchanged at 135/83/41/9/2).
Every line below is a re-derivation recipe, not a conclusion.

## Roster census (paginated, never a single capped call)

    bp task ls --all -o json > /tmp/allt.json
    python3 -c "import json;from collections import Counter;d=json.load(open('/tmp/allt.json'));k=[x for x in d['docs'] if x.get('parent_id')=='cloud-console-hardening-epic'];print(len(k),Counter(x.get('lifecycle_status') for x in k))"

## Which write verbs reach the PUBLISHED perspective

    # LANDS on published (no republish, no wall):
    bp task close <id> <worker> <epoch> [done|cancelled] "<reason>"   -> content.close_reason
    bp task stage <id> considering --note "<why>"                     -> content.disposition_reason
    bp task move  <id> <new_parent> --yes                             -> parent_id

    # DOES NOT land on published — writes the DRAFT only:
    bp doc patch task <id> --set disposition_reason='...'  --yes
    bp doc get   task <id> --perspective published -o json   # still shows the OLD value

## Close gates actually observed

    # unclaimed row, any epoch -> closes
    # released claim (claim.worker == null, released_by set) -> STILL held:
    bp task close <id> <w> <wrong-epoch>   # {"code":"fenced_off"}
    bp task close <id> <w> <right-epoch>   # {"code":"not_holder:<released_by>"}
    bp task close <id> <w> <right-epoch> done "<reason>" \
      --set holder_override="<why you are closing someone else's claim>"   # lands
    # -> content.close_override.holder {actor, held_by, reason, ts}

Rows in this epic that need holder_override (epoch 2, released_by
`epic-builder-census-truth-pass-evidence-close-the-ver`):
gr-backlog-provider-reconnect, gr-backlog-tfa-confirm-throttle,
task-04054d483ae95bd1, gr-backlog-css-check-missing-classes,
gr-backlog-cssom-parity-count-skew.
gr-p5r5-successor-seal is a different shape: EXPIRED claim
(`expired_at`, `previous_worker: lead-truthgrip`, epoch 2) — untested.

    python3 -c "import json;d=json.load(open('/tmp/allt.json'));[print(x['doc_id'],x['claim']) for x in d['docs'] if x.get('parent_id')=='cloud-console-hardening-epic' and x.get('lifecycle_status') in ('open','considering') and x.get('claim')]"

## Publish wall (only matters if you use bp doc patch and then republish)

    bp doc publish task <id> --yes    # 422 label_spine when tags are null/unregistered
                                      # 409 duplicate_of on a near-duplicate publish

Three open children carry NO tags and would 422 on republish:
pp-b-branch-protection, task-1f8bcab494ac0a3a, cloud-console-operator-audit-log.
Mitigation: never republish them — use stage/close/move, which bypass the wall.

## GitHub mirror

    gh issue view <n> -R FRIKKern/barkpark --json state,labels

* close/cancel converge the issue in ~40s (`status:done` / `status:cancelled`, CLOSED).
* re-parent converges the `goal:<parent>` label in ~40s — the label is derived
  live from `parent_id` (api/lib/barkpark/plugins/github/projection.ex `labels/1`).
* `content.github.parent_marker` is the D11 cap-flatten body fence and is only
  ever re-stamped on the flatten branch (`handle_flatten/5` in
  api/lib/barkpark/plugins/github/mirror_job.ex). A re-parent that links
  NATIVELY leaves the OLD marker in place — nothing clears it.
* The mirror loads the task **draft-first** (`load_task/3`, mirror_job.ex).
  A stale draft twin FREEZES the issue to that snapshot: a probe whose published
  row was cancelled and re-parented kept `status:open` and no goal label.
* `bp doc delete task <id>` ORPHANS the issue — it stays in whatever state it
  was in (a still-open probe issue stayed OPEN with no ledger row behind it).
  Cancel first, let the mirror converge, only then delete — or never delete.

## Server reliability during the rehearsal (~25 min window)

    bp task create ...   # 1 client timeout, 2x "unknown error" (bare, no request_id)
    bp task ls --all     # 1x internal_error
    /v1/capabilities     # 1x 500
No orphan row survived the timed-out create (verified by title scan).
