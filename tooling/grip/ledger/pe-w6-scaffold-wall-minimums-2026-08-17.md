<!-- doc-tier: cold | canonical-for: pe-w6-scaffold-wall-minimums-rederivation | budget: 1500tok -->

# pe-w6 scaffold-wall-minimums — re-derivation recipe

Verifier: scaffold-wall-minimums (Paper Excellence wave 6). All anchors from `origin/main`; live proofs against `guerrilla.barkpark.cloud`.

## The three gates in full (read on origin/main)

    git show origin/main:api/lib/barkpark/content/label_spine.ex          # E1/E2 — description + weighted-tag shape
    git show origin/main:api/lib/barkpark/content/tag_registry.ex         # E3 — every tags[].tag must be a published type:tag doc
    git show origin/main:api/lib/barkpark/content/papers/hollow.ex        # hollow-body predicate
    git show origin/main:api/lib/barkpark/content/authoring_wall.ex       # validate_all/5 gate order
    git show origin/main:api/lib/barkpark/content/papers/epic_quality.ex  # canonical? gate — fires ONLY on tag "epic-cycle-wave-paper"
    git show origin/main:api/lib/barkpark/content/papers/template.ex      # validate/1 — no-op unless a locked block is present
    git show origin/main:api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex  # validate action, lines ~119-170

## Enumerate registered tags

    TOK=<bp_admin token from ~/.config/barkpark/config.json>
    curl -s -H "Authorization: Bearer $TOK" 'https://guerrilla.barkpark.cloud/v1/data/query/production/tag?limit=500&fields=_id' \
      | python3 -c "import sys,json;print('\n'.join(sorted(x['_id'] for x in json.load(sys.stdin)['result']['documents'])))"
    # → 193 registered tags on 2026-08-17. Result nests under result.documents.

## Prove the wall (dry-run, nothing persisted)

    curl -s -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
      'https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers/validate' -d @starter.json

- starter.json (locked title @ index 0 + one paragraph, description >=20 chars, 2 REGISTERED weighted tags, distinct strengths) → `{"valid":true,"violations":[]}`.
- tagless/hollow (only a locked heading, no description, no tags) → label_spine (description) + hollow_paper.
- unregistered tag → `unknown_tag` with suggestions map.

Top-level POST keys: slug, title, description, tags, blocks. The controller builds content.{blocks,tags,description} from them — description/tags are NOT nested in blocks.
