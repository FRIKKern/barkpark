# Wall-dialect template + are refusals debuggable — re-derivation recipe (2026-08-12)

Verifier lane `v4-wall-template`, epic-cycle-distribution wave 1.

## What the wall enforces (origin/main, tag-scoped)

    git show origin/main:api/lib/barkpark/content/papers/epic_quality.ex | sed -n '18,28p'

`@canonical_tag "epic-cycle-wave-paper"` · `@opening_window 8` ·
`@orientation_types ~w(byline stats toc list steps)` · `@max_primary_words 5_000` ·
`@max_top_level_blocks 80` · `@max_top_level_headings 16` ·
`@required_readers ~w(public studio tui80 email cli_api)` (only checked when the
content declares `reader_checks`).

Hard failures include `:empty_paragraph_spacer` — computed over ALL nested maps,
not just top level:

    git show origin/main:api/lib/barkpark/content/papers/epic_quality.ex | sed -n '88,102p'

## The two proven-passing openings

    bp doc get paper epic-cycle-distribution-wave-2026-08-12 -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print([(b.get('type'),b.get('level')) for b in d['blocks'][:8]]);print(d['tags'])"
    bp doc get paper cloud-console-hardening-wave-67-2026-08-10 -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print([(b.get('type'),b.get('level')) for b in d['blocks'][:8]])"

This wave's paper: `heading/1 → ingress → list → heading/2 → …`, 32 top-level
blocks, 9 headings, ONE h1, ZERO empty paragraphs anywhere.
Wave 67: `heading/1 → ingress → stats → heading/2 → paragraph → heading/2 →
paragraph → table`, 49 blocks, 10 headings.

Spacer count re-derivation (must print 0):

    bp doc get paper <slug> -o json | python3 -c "
    import json,sys
    def walk(o):
        if isinstance(o,dict):
            yield o
            for v in o.values(): yield from walk(v)
        elif isinstance(o,list):
            for v in o: yield from walk(v)
    b=json.load(sys.stdin)['blocks']
    print(sum(1 for m in walk(b) if m.get('type')=='paragraph' and not m.get('content')))"

## Are refusals debuggable?

    git log --oneline -3 origin/main -- api/test/barkpark_web/controllers/bulldocs_ingest_wall_test.exs
    git grep -n 'invalid_epic_paper_quality' origin/main -- api/lib
    git show origin/main:api/lib/barkpark_web/controllers/mutate_controller.ex | grep -n 'Errors\.\|details'
    git grep -n 'invalid_op' origin/main -- api/lib/barkpark_web | head

`dr-w32-s1` merged as `5a11c43dbb` (#11422): 422 with
`details.failures = [named atoms]`, wired on all three ingest legs and carried by
`Errors.build/1` (errors.ex:481). `/v1/data/mutate` (the engine's authoring path)
renders through `Errors.to_envelope`, so failures reach `bp`. The
`/papers/:slug/ops` route still answers bare `invalid_op` with no details —
`dr-w32-bl-ops-route-discards-the-wall-failure-names`, still open.

## Open contradiction ticket

    bp task get cchi-w67-bl-the-epic-paper-floor-forbids-the-spacing-doctrine -o json \
      | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['criteria_progress'])"

`open`, 0/3, parent `cch-instruments-epic`, untouched since 2026-08-10.

## Engine gap

    grep -c 'ingress' .claude/workflows/bp-epic-cycle.workflow.js         # 0
    grep -c 'epic-cycle-wave-paper' .claude/workflows/bp-epic-cycle.workflow.js  # 0
    sed -n '158p' .claude/workflows/bp-epic-cycle.workflow.js             # the spacer instruction

The engine teaches spacers (a hard failure) and teaches nothing about the tag,
the h1/ingress/orientation opening, or the block/heading ceilings.
