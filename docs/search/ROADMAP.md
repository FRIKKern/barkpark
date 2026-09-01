<!-- doc-tier: agent | canonical-for: search-roadmap | budget: 500tok -->
# Search Intelligence Roadmap

**Principle:** Postgres remembers and explains; search engines retrieve. No Algolia/Typesense dependency until Postgres search latency fails SLA.

**Phases 0–8 shipped** (May 2026): surface-safe indexes; suggest (recent/popular/nohits — popular + nohits crystal-backed, recent raw-events actor-scoped; `min_search_count: 3`, `X-BP-Search-Disable`); click/CTR; quality gates + telemetry; synonym loop (`search_synonyms`, candidates, `searchCountDelta`); document FTS hybrid (`search_vector` + ILIKE + trgm); relevance (`QueryPipeline`, `QueryParser`, `Highlighter`, `SurfaceConfig`, zero-hit recovery); golden eval (`mix search.eval`); federated search + shared `bp-search-intel.js`. Retention: 90-day raw events, crystals indefinite. Architecture: [`INTELLIGENCE.md`](INTELLIGENCE.md). Earlier phase-6–10 design notes were removed; recover from git history.

## Phase 9 — Scale & ops (trigger-based)

**Triggers: events > 5M/scope, prune > 30s, or suggest p95 > 50ms at 100k events.**

Work: Oban async record (API returns immediately); monthly RANGE partitions on `inserted_at` (DROP not DELETE); crystal retention day 90d / week+month 2y; SQL crystallize (`INSERT…SELECT`) when >100k events/day.

## Phase 10 — External retriever — SHIPPED (not pain-gated any more)

The seam landed as `Barkpark.Search.Retriever` and the engine as `Barkpark.Plugins.Indx.Retriever`, registered by default in `config :barkpark, :search_retrievers` and reachable per request as `?engine=indx` (default `postgres`). Credentials come from `INDX_API_BASE` / `INDX_USER_EMAIL` in `runtime.exs`. **Intelligence did stay in Postgres** — the retriever returns documents and records no events. Typesense and Algolia were never adopted, and the >500k-assets / fuzzy-p95 triggers are moot.

## What we deliberately skip

| Feature | Reason |
|---------|--------|
| Algolia Recommend ML | No co-purchase graph; CMS not storefront |
| Personalized suggestions | Needs click volume + user profiles |
| Full Rules / merchandising engine | CMS editorial workflow differs |
| Algolia SaaS | Never adopted; Phase 10 landed on the self-hosted Indx engine instead |
| Vector semantic search | Defer until lexical ceiling hit; adds ops cost |
| Redis for recent | Actor-key query fine until Phase 9 |
| Vector/semantic embeddings | Still absent — no pgvector, no embedding column anywhere in `api/` |

## Code anchors

- `api/lib/barkpark/search/query_pipeline.ex` — `Barkpark.Search.QueryPipeline`
- `api/lib/mix/tasks/search.eval.ex` — `mix search.eval`
- `api/lib/barkpark_web/controllers/federated_search_controller.ex` — federated endpoint
- `api/priv/static/assets/bp-search-intel.js` — shared client module
