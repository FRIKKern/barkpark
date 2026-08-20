# Re-derivation recipe — honest-close two-arm run (cch wave 66, Clause A)

STATUS: **NOT RUN.** The verify host had no shell — every `Bash` call, including
`df -h /`, died with
`ENOSPC: no space left on device, open '/private/tmp/claude-501/-Volumes-SATECHI-github-barkpark/d10b01bb-.../tasks/*.output'`.
Three surveyors hit the same wall. This file is the exact recipe so the run is a
paste, not a re-derivation, the moment disk exists.

## What the run must decide

Whether an honest lead close of a MERGED, marker-bearing row lands evidence with
**no `close_override` key at all** — and whether the refusal arm can lose.

## Recipe (isolated scratch dataset — NEVER the production task ledger)

    BP=https://guerrilla.barkpark.cloud
    TOK=$(jq -r .token ~/.config/barkpark/config.json)   # confirm shape first
    DS=cchw66scratch

    # ARM 1 — marker + landed  ⇒ expect ok:true, evidence stamped, NO close_override
    bp task create --dataset "$DS" --title 'w66 arm1' \
      --set 'acceptance_criteria:=[{"criterion":"MERGE-GATED: PR merges","met":false,"merge_gate":true},{"criterion":"ordinary","met":true}]'
    bp task next w66probe --dataset "$DS"           # capture id + epoch
    bp task close <id> w66probe <epoch> --set 'landed:={"prs":[11486]}'
    curl -sG "$BP/v1/data/query/$DS/task" --data-urlencode 'perspective=drafts' \
      -H "Authorization: Bearer $TOK" | jq '.documents[] | {doc_id,acceptance_criteria:.content.acceptance_criteria,close_override:.content.close_override}'

    # ARM 2 — marker, NO landed ⇒ expect 409 reason "criteria_unmet:0"
    #   (wire token built by Params.reason_to_string/1, params.ex:622-623)

    # MUTATION PROOF — strip "merge_gate":true, keep the MERGE-GATED prose,
    #   re-run the ARM-1 close ⇒ must NOT deduct, must refuse criteria_unmet:0.
    #   If it still passes, the marker is not the thing doing the work.

    # CLEANUP: discard/unpublish every doc in $DS.

## Static (L4, source-read) expectations the run must confirm or break

* `api/lib/barkpark/tasks/close.ex:455-468` `unmet_after_autostamp/2` — when
  `landed` is a non-empty map, every `merge_gate:true` index is rejected from the
  unmet list.
* `:437-448` `check_criteria_proven/4` — empty unmet ⇒ `{:ok, nil}`; `:474`
  `compose_override_record(nil, nil, _)` ⇒ `nil` ⇒ **no `close_override` written**.
* `:707-724` `merge_gate_synthetics/3` — stamps only on the EXPLICIT
  `"merge_gate" => true` marker, never met, not caller-targeted, non-empty
  `criterion` text (D56 guardable text). This is what the mutation proof attacks.
* `api/lib/barkpark_web/controllers/tasks_controller.ex:484`
  `Params.put_opt(:landed, params["landed"])` — the client's `landed` is an
  UNVALIDATED passthrough. No lead check, no PR verification. This is the
  autostamp-authority hole, not a marker-reachability problem.

## Unverified

`TasksController.Params.parse_criteria_entry/1`'s four-key allowlist (the claimed
create-vs-update retrofit asymmetry) was NOT located in `params.ex` on this pass.
