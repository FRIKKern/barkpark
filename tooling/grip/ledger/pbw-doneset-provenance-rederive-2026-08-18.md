<!-- doc-tier: cold | canonical-for: pbw-doneset-provenance-rederivation | budget: 600tok -->

# PD Block-Wishlist done-set: engine-close provenance re-derivation (2026-08-18)

Re-derives the correction of record for the PD Block-Wishlist done-set false-done audit:
the direction's "central finding" (all 12 pbw-stier-* closed with claim.closed_by=null /
worker=null / epoch=null — the Felix fabrication shape) is REFUTED on live L1.

## Fact 1 — ZERO null-claim rows across all 17 done children

    for t in pbw-w1-wishlist-100-paper pbw-w1-usefulness-review-paper pbw-w1-reader-resolver-fix pbw-w1-broken-blocks-fix pbw-w1-stale-comment-truth pbw-stier-toc pbw-stier-steps pbw-stier-bar-chart pbw-stier-equation pbw-stier-api-endpoint pbw-stier-code-tabs pbw-stier-tabs pbw-stier-video pbw-stier-field-number pbw-stier-expandable pbw-stier-footnote pbw-stier-criteria-progress; do bp task get $t -o json | python3 -c "import sys,json;d=json.load(sys.stdin)['doc'];c=d.get('claim') or {};print('$t',c.get('closed_by'),c.get('worker'),c.get('epoch'),bool(c.get('work_digest')),'|',d['content'].get('close_reason','')[:60])"; done

Every row prints a NON-NULL closed_by/worker (lead-wishlist, stier-wave-lead,
stier-r2-builder, epic-builder-usefulness-review-...), a non-null epoch (w1: 6-9;
stier: 3 or 5), and work_digest=True. No `None None None` row exists. Premise REFUTED.

## Fact 2 — cohort split: 14 reconcile-boilerplate + 3 bespoke

Reconcile-boilerplate ("Historical completion reconciled from N/N met acceptance cri"): 14 rows —
pbw-w1-reader-resolver-fix, pbw-w1-broken-blocks-fix, and all 12 pbw-stier-* except none excluded
(toc, steps, bar-chart, equation, api-endpoint, code-tabs, tabs, video, field-number, expandable,
footnote, criteria-progress).
Bespoke close_reason (3): pbw-w1-wishlist-100-paper (PR #4049), pbw-w1-usefulness-review-paper
(paper rev 6), pbw-w1-stale-comment-truth (run-convert.js comment correction).

## Fact 3 — reconcile paper excuses the boilerplate cohort

    bp paper view pd-block-wishlist-wave-2026-08-18 | grep -iE 'RECONCILE|ALREADY SHIPPED|TWELVE'

Prints: "WAVE 2 RECONCILED: THE TWELVE ALREADY SHIPPED", "RECONCILE-AND-CLOSE-BY-EVIDENCE:
the twelve are shipped; nothing is rebuilt.", "RECONCILE CONFIRMED by three independent
surveyors". The 14 boilerplate closes are documented reconciles by named workers, NOT
fabrications. Sweep B contributes ZERO reopens on provenance grounds.
