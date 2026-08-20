<!-- doc-tier: cold | canonical-for: none | budget: 800tok -->
# TLV done-set audit — SWEEP-B provenance closeout (null-worker closes) — 2026-08-18

Re-derivation recipes for the 3 `closed_by="None"` closes in the task-lifecycle-visibility
done set, the engine sentinel guard, and the decision-lane authorities. All reads on
origin/main (fetched 2026-08-18). READ-ONLY audit; no reopen issued (0 false-done).

## The 3 null-worker closes — provenance

    # #5709 true-blocking-primitive-decision: DOCUMENTED reconcile-close (EXCUSED)
    bp task get tlv-bl-true-blocking-primitive-decision -o json </dev/null \
      | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['close_reason']);print(d['claim']['now']['text'])"
    #   close_reason = "RULED: charter D25 — advisory blocking is FINAL ... Merged 8b7777e0c (#5709). Invariant test-locked (#5537)."
    #   claim.now.text = "LEAD RULED option (a): ruling = D25 ..." (ts 2026-07-22T12:18)

    # #5705 s1 stage-help (task-13bc8127adedfee0): merged-PR only, NO paper authorization line
    bp task get task-13bc8127adedfee0 -o json </dev/null   # close_reason EMPTY; claim.now = build digest "crit 2 (PR merged) awaits lead"
    git log origin/main --oneline | grep '(#5705)'         # c729189ff2  (ancestor)
    git merge-base --is-ancestor c729189ff2 origin/main && echo ANCESTOR

    # #5707 s4 js-vocab drift-gate: merged-PR only; reconciliation paper vetted the SHA
    bp task get tlv-bl-js-vocab-drift-gate -o json </dev/null  # close_reason EMPTY; claim.now = build digest
    git log origin/main --oneline | grep '(#5707)'             # c86cc62fe1  (ancestor)
    git merge-base --is-ancestor c86cc62fe1 origin/main && echo ANCESTOR
    #   reconciliation paper task-lifecycle-visibility-wave-2026-08-18: "#5707 BUILDS the DONE
    #   drift-gate sibling and explicitly DEFERS the generator" — DONE row is the drift gate, built.

All 3 carry criteria_met==total (3/3). None is false-done. #5709 has a full documented
reconcile ruling; #5705 and #5707 rest on merged-PR + stamped 3/3 only (thin provenance,
not fabrication).

## Engine sentinel guard — the "None" hole is now closed

    git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '90,93p'
    #   match?({:error, _}, check_worker_id(worker_id)) -> check_worker_id(worker_id)
    git show origin/main:api/lib/barkpark/tasks/internal.ex | sed -n '173,190p'
    #   @sentinel_worker_ids ~w(none null nil -)  + ""  -> {:error, {:sentinel_worker_id, _}}
    git show -s --format='%ci %s' 448749cf18   # 2026-07-28  guard landed (#6420, PDS-D290)
    # Closes were 2026-07-22 -> PRE-guard close path accepted worker="None" (stringified null
    # from a lead reconcile-close template). Current origin/main refuses exactly that shape.

## Decision-lane authorities (coverage, not mere existence)

    git show origin/main:.claude/workflows/bp-studio-space-priority-charter.md | sed -n '1751,1760p'
    #   D212: "b24 ... straight verdict-close ... CLOSE with ruling; the deferred true-blocking-
    #   primitive decision survives as new tlv backlog row tlv-bl-true-blocking-primitive-decision"
    git show origin/main:.claude/workflows/bp-task-lifecycle-visibility-charter.md | sed -n '164,182p'
    #   D25: "advisory blocking is FINAL ... SUPERSEDES the phantom 'D32' citation that
    #   tlv-bl-true-blocking-primitive-decision was authored against"
    git show origin/main:.claude/workflows/bp-task-lifecycle-visibility-charter.md | sed -n '78,84p'
    #   D6: "axis-2 cancelled-blocker stranding is an EXPLICIT DEFERRAL (backlog task
    #   tlv-bl-axis2-cancelled-strand)" — the authority the axis-2 row closes against.
