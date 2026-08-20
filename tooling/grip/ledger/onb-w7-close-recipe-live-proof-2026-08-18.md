<!-- doc-tier: cold | canonical-for: onb-w7-close-recipe-live-proof | budget: 2000tok -->

# onb-w7 close-recipe live proof (2026-08-18)

Re-derivation recipe for wave-7 verifier finding [V3-close-recipe-live]. Against
live guerrilla (https://guerrilla.barkpark.cloud), the raw-mutate open→done close
recipe assumed by the wish/digest is REFUTED: open→done is illegal via ANY document
write, ifRevisionID notwithstanding.

## Re-run (throwaway probe)

    TOKEN=<bp_admin token from ~/.config/barkpark/config>
    bp doc create task --set _id=w7-close-rehearsal-probe --set 'title=...' \
        --set kind=task --set lifecycle_status=open --yes

    # (a) no ifRevisionID, set lifecycle_status=done  -> HTTP 422 validation_failed
    #     details.lifecycle_status = "...without a revision precondition..."
    #     (mutations.ex:461 close_bypass_error / ensure_task_close_is_cas)
    curl -sX POST $HOST/v1/data/mutate/production -H "Authorization: Bearer $TOKEN" \
      -d '{"mutations":[{"patch":{"id":"w7-close-rehearsal-probe","type":"task","set":{"lifecycle_status":"done"}}}]}'

    # (b) stale ifRevisionID -> HTTP 412 precondition_failed (NOT 409!)
    #     code=precondition_failed, details.actual/expected
    # (c) FRESH ifRevisionID + lifecycle_status=done -> HTTP 422 validation_failed
    #     details.lifecycle_status = 'illegal lifecycle transition "open" -> "done":
    #     no document write may perform it' (writer.ex:995 illegal_transition_error;
    #     Transitions.legal?("open","done")==false — {open,done} not in @legal_pairs)
    # (d) FRESH ifRevisionID + acceptance_criteria ONLY (no lifecycle change)
    #     -> HTTP 200, criteria met:true+evidence land in the DRAFT verbatim

## The actual working close (proven live)

The lifecycle flip to done goes through the close primitive, never mutate:

    bp task close w7-close-rehearsal-probe <worker> <epoch> done "<reason>" \
      --set 'criteria:=[{"index":0,"met":true,"evidence":"...","criterion":"<exact stored text>"}]'

Works on an UNCLAIMED task: observed_epoch is arbitrary (check_fencing close.ex:389
passes with no claim lease). Flips lifecycle=done AND stamps criteria met/evidence
atomically under criterion-text CAS (met-flip needs exact criterion text or 409
criterion_text_required / criteria_mismatch). Read-back: lifecycle=done, criteria verbatim.

## Anchors

- api/lib/barkpark/content/writer.ex:690 ensure_task_transition_legal (transition gate — SUPERSEDES the rev escape for illegal transitions, D7a)
- api/lib/barkpark/tasks/transitions.ex:46 @legal_pairs ({open,done} ABSENT)
- api/lib/barkpark/content/mutations.ex:440 ensure_task_close_is_cas (no-rev 422)
- api/lib/barkpark/tasks/close.ex:389 check_fencing (unclaimed closes cleanly), :449 check_criteria_proven
