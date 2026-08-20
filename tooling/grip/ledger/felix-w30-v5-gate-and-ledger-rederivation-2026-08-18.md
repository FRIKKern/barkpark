# Felix wave-30 V5 — gate & ledger re-derivation recipes (2026-08-18)

Re-derive each fact before Decide acts. All observed ~01:41 UTC 2026-08-18.

## #12132 (media-mirror) — NOT yet green, still BLOCKED/OPEN

    gh pr view 12132 --json state,mergeable,mergeStateStatus
    # -> state=OPEN, mergeable=MERGEABLE, mergeStateStatus=BLOCKED
    gh pr checks 12132 | grep -iE "Test \(Elixir|Compose smoke$|Green arm|Sobelow"
    # -> Test (Elixir 1.18.1 / OTP 27.0)  pending   (IN_PROGRESS, conclusion empty) — the ONE required gate, not concluded
    # -> Green arm / Compose smoke / Sobelow static  = FAIL  (all NON-required; do not block)

The wish step-1 close of felix-w27-bl-media-dataset-swallow-mirror does NOT fire: PR unmerged.

## felix-w27-s6-12041-golden-contingency — closeable, epoch 7

    bp task get felix-w27-s6-12041-golden-contingency -o json
    # lifecycle=open ; claim.epoch=7 ; claim.worker=null (expired 2026-08-17T23:25Z)
    # assignee = epic-builder-12041-lands-diagnose-the-shifting-elixir
    # criteria 2/3 met; crit-3 (merge-gated on PR #12041) was empty
    gh pr view 12041 --json state,mergedAt
    # -> state=MERGED, mergedAt=2026-08-18T00:10:32Z  => crit-3 now satisfiable, D198 close is due
    # CLOSE ON EPOCH 7 (a prior survey said 5 — STALE; epoch advanced to 7).

## Four wave-28 landed rows — all sealed (task=done AND PR=merged)

    for p in 12109 12111 12113 12114; do gh pr view $p --json state,mergedAt; done
    # all MERGED ~2026-08-18T00:40Z
    # PR->task trailers: 12109=felix-w26-bl-s3-blob-receive-timeout ;
    #   12111=felix-w27-bl-checkout-docstring-honesty ;
    #   12113=felix-w28-s4-pulse-metrics-deflake ;
    #   12114=task-felix-w14-sync-deadletter-classification
    for t in felix-w26-bl-s3-blob-receive-timeout felix-w27-bl-checkout-docstring-honesty \
             felix-w28-s4-pulse-metrics-deflake task-felix-w14-sync-deadletter-classification; do
      bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'])"
    done
    # all -> done   (closed by lead-loop; no wave-30 action owed on these)

## task-1c95d48422bad590 (E5b field-visibility seal) — code sealed on main, only crit-4 unmet

    bp task get task-1c95d48422bad590 -o json
    # lifecycle=open ; criteria 3/4 met ; crit-4 (Elixir gate + merged PR referencing task) = empty/unmet
    # crits 1-3 stamped with RED->GREEN mutation evidence (params.ex:190 + sheets_reader_live.ex sealed;
    #   PR #5826 opened by felix-w17, claim epoch 4 worker=null expired 2026-07-23).
    # This is the E5b sweep the wave-30 census leans on: two fail-open paths sealed, leak latent (zero
    #   schema fields declare per-field visibility). Bookkeeping open only on crit-4 (merge stamp).
