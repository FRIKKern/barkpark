<!-- doc-tier: cold | canonical-for: tlv-reparent-target-liveness-recipe | budget: 900tok -->
# TLV reconcile wave — re-parent target liveness (verifier recipe)

Re-derivation recipes for the reparent-target-liveness verdict on the
task-lifecycle-visibility reconcile wave (2026-08-18). Re-run these to
re-prove each verdict from live L1.

## Target epic liveness (each returns lifecycle_status + parent_id)

    bp task get task-2ac1f95237c4a8e5 -o json | jq '.doc | {lifecycle_status, parent_id, updated_at}'
    # -> open, parent_id=null (top-level), updated 2026-08-05  => PDS epic LIVE, accepting

    bp task get cloud-console-hardening-epic -o json | jq '.doc | {lifecycle_status, parent_id, updated_at}'
    # -> open, but updated 2026-08-18 (TODAY) — epic is in its TERMINAL CLOSE wave

## cloud-console-hardening is CLOSING NOW — do NOT re-home into it

    bp task get cch-w77-s2-terminal-close-reconcile-and-residue-map -o json | jq '.doc.body.acceptance_criteria'
    # criterion 1: NO-SEAL verdict a=FAIL b=PASS c=PASS orphans=427, "closes on the RULING per D889"
    # criterion 2: residue map — "D93 pacing: publish MAP only, no re-homing this wave"
    #   destinations: cch-instruments-epic | task-47bc4168392dec17 | STAY
    bp task get cch-instruments-epic -o json | jq '.doc.lifecycle_status'      # open, top-level
    bp task get task-47bc4168392dec17 -o json | jq '.doc.lifecycle_status'     # open, top-level (Cloud GUI remake BUILD)

## Current parentage of the two candidate movers

    bp task get pds-bl-merge-gated-criteria-carry-the-flag -o json | jq '.doc.parent_id'
    # task-lifecycle-visibility-epic (mis-parented; belongs to PDS)
    bp task get cloud-console-data-query-id-prefix-bug -o json | jq '.doc | {parent_id, title}'
    # parent task-lifecycle-visibility-epic; title "/v1/data/query id_prefix param silently ignored" = api/-side

## task-system umbrella probe — NONE exists

    bp search query "task system engine epic parent umbrella lifecycle board"
    # only hit is task-lifecycle-visibility-epic itself. No separate task-system engine epic.
    # => eal/spd/graph/task-hash rows STAY; TLV epic IS their umbrella.

## Verdicts (per-row)

- pds-bl-merge-gated-criteria-carry-the-flag  -> MOVE to task-2ac1f95237c4a8e5
      bp task move pds-bl-merge-gated-criteria-carry-the-flag task-2ac1f95237c4a8e5
- cloud-console-data-query-id-prefix-bug      -> KEEP (console epic closing; bug is api/-side, not cloud-GUI)
- task-eal-bl-lock-key-convergence            -> KEEP (no foreign epic)
- task-eal-bl-events-cold-index (considering) -> KEEP (epic-native per survey)
- task-eal-bl-cmux-auto-pulse                 -> KEEP (no foreign epic)
- spd-b44-slug-allocator-assigns-not-guesses  -> KEEP (no foreign epic)
- graph-endpoint-latency                      -> KEEP (no foreign epic)
- task-6e819.../task-11390... (task-hash)     -> KEEP (no foreign epic)

Only ONE clean mover: the PDS row. All others STAY.
