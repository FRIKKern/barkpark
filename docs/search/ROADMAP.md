<!-- doc-tier: agent | canonical-for: search-roadmap | budget: 500tok -->
# Search Intelligence Roadmap

**Principle:** Postgres remembers and explains; search engines retrieve. No Algolia/Typesense dependency until Postgres search latency fails SLA.

**Phases 0–8 shipped** (May 2026): surface-safe indexes; crystal-backed suggest (recent/popular/nohits, `min_search_count: 3`, `X-BP-Search-Disable`); click/CTR; quality gates + telemetry; synonym loop (`search_synonyms`, candidates, `searchCountDelta`); document FTS hybrid (`search_vector` + ILIKE + trgm); relevance (`QueryPipeline`, `QueryParser`, `Highlighter`, `SurfaceConfig`, zero-hit recovery); golden eval (`mix search.eval`); federated search + shared `bp-search-intel.js`. Retention: 90-day raw events, crystals indefinite. Architecture: [`INTELLIGENCE.md`](INTELLIGENCE.md); design notes attic'd: `_attic/docs-2026-06/docs/search/PLAN-PHASES-6-10.md`.

## Phase 9 — Scale & ops (trigger-based)

**Triggers: events > 5M/scope, prune > 30s, or suggest p95 > 50ms at 100k events.**

Work: Oban async record (API returns immediately); monthly RANGE partitions on `inserted_at` (DROP not DELETE); crystal retention day 90d / week+month 2y; SQL crystallize (`INSERT…SELECT`) when >100k events/day.

## Phase 10 — Optional external retriever (pain-gated)

**Triggers: >500k media assets OR fuzzy p95 > 100ms.**

Typesense collection per surface; **intelligence stays in Postgres** (mirror hits to record events only); skip Algolia SaaS unless enterprise mandate. Spike doc only until a trigger fires.

## What we deliberately skip

| Feature | Reason |
|---------|--------|
| Algolia Recommend ML | No co-purchase graph; CMS not storefront |
| Personalized suggestions | Needs click volume + user profiles |
| Full Rules / merchandising engine | CMS editorial workflow differs |
| Algolia SaaS | Postgres sufficient until Phase 10 trigger |
| Vector semantic search | Defer until lexical ceiling hit; adds ops cost |
| Redis for recent | Actor-key query fine until Phase 9 |

## Code anchors

- `api/lib/barkpark/search/query_pipeline.ex` — `Barkpark.Search.QueryPipeline`
- `api/lib/mix/tasks/search.eval.ex` — `mix search.eval`
- `api/lib/barkpark_web/controllers/federated_search_controller.ex` — federated endpoint
- `api/priv/static/assets/bp-search-intel.js` — shared client module
