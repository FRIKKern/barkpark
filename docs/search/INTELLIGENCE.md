<!-- doc-tier: agent | canonical-for: search-intelligence | budget: 1800tok -->
# Search Intelligence (Barkpark core)

Surface-agnostic search analytics, crystallization, and improvement signals.
Product surfaces (Media DAM, document search) plug in via thin adapters:
adapter translates native API params → core context map → `Barkpark.Search.Intelligence`
(record · suggestions · insights · prune) → Postgres `search_intel_*` tables
keyed by `surface` + `scope`. Quality gate: `Barkpark.Search.Sanitizer`;
rollups: `Barkpark.Search.Crystallizer`.

## Design principles (do not break)

1. **Intelligence stays in Postgres** — events, crystals, synonyms, merge patterns. No analytics in the external retriever. Phase 10 landed (Indx) and this held: `Indx.Retriever` returns documents and records no events.
2. **Surfaces stay thin** — adapters translate params; core owns rollups and improvement signals.
3. **Search never blocks on analytics** — the record path must remain async-safe (Phase 9 makes this strict).
4. **Every ranking change is measurable** — golden-query harness before/after (`mix search.eval`).
5. **Admin promotes evidence, not hunches** — synonym candidates carry CTR, transitions, confidence.

## Analytics ops contract

- **Crystallize** nightly at **03:30 UTC** (`Barkpark.Search.Workers.Crystallize`, Oban cron `"30 3 * * *"`) — rolls raw events into day/week/month crystals + merge patterns.
- **Prune** raw events at **04:00 UTC** (`Barkpark.Search.Workers.Prune`, cron `"0 4 * * *"`); retention default **90 days** (`@retention_days 90` in `intelligence.ex`). **Crystals persist indefinitely.**
- **Lineage:** `X-BP-Search-Parent` carries the previous event id to link refinement chains; the crystallizer additionally infers chains within **30 min** per actor when the header is absent.

## Key concepts

| Term | Meaning | Media DAM example |
|------|---------|-------------------|
| **surface** | Product area | `"media"` |
| **scope** | Tenant partition | `"production"` (dataset) |
| **context** | Normalized search state | `%{query, filters, offset}` |
| **crystal** | Day/week/month aggregate | Popular query + filter fingerprint |
| **merge pattern** | Refinement transition | `zero_to_hit`, `facet_add` |

Schemas: `Barkpark.Search.{Event, Crystal, MergePattern, Synonym}` (synonym map
+ candidates, Phase 4). The plural `Barkpark.Search.Synonyms` is the CONTEXT module,
not a schema — the Ecto schema over `search_synonyms` is the singular `Synonym`.

## Adapters

`Barkpark.Search.MediaIntelligence` is the only module Media Desk / v1 media API
should call; WoodWing-style facet params are translated via `MediaSearchParams`
inside the adapter. `Barkpark.Content.SearchIntelligence` wraps the documents
search route with `surface: "documents"`; filters captured: `type`,
`perspective` (`published` | `drafts` | `raw`).

```elixir
SearchIntelligence.record("production", conn_params, total, ms,
  actor_key: "...", parent_event_id: "...", source: "explorer")
```

## HTTP (documents surface)

Endpoints live under the workspace + project prefix (canonical). Flat
`/v1/data/search/*` paths remain as the `Default`/`Default` back-compat alias —
see `docs/api-v1.md` §1a.

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `GET /w/:workspace_slug/p/:project_slug/v1/data/search/:dataset` | optional | Hybrid title search (+ `searchEventId`) |
| `GET …/search/:dataset/suggestions` | optional | Recent / popular / nohits |
| `GET …/search/:dataset/insights` | admin | Crystals, merge patterns, hints, synonymCandidates |
| `GET …/search/:dataset/synonyms` | admin | List synonym map |
| `POST …/search/:dataset/synonyms` | admin | Create synonym |
| `DELETE …/search/:dataset/synonyms/:id` | admin | Delete synonym |

**Media surface:** the same six routes exist under
`/w/:workspace_slug/p/:project_slug/v1/media/:dataset/search[…]` with identical
auth. Flat aliases for both surfaces
(`/v1/data/search/:dataset…`, `/v1/media/:dataset/search…`) resolve the
`Default` workspace + project.

Headers for lineage (all surfaces): `X-BP-Search-Client` (session actor) ·
`X-BP-Search-Parent` (previous event id, refinement chain) ·
`X-BP-Search-Source` (`explorer`, `picker`, `studio-picker`, `api`).
Shared conn helpers: `BarkparkWeb.SearchIntel`.

## Adding a new surface

1. Pick a `surface` string (e.g. `"documents"`).
2. Implement an adapter that builds `%{query, filters, offset}` from native params.
3. Call `Barkpark.Search.Intelligence.record/6` — no new tables required.
4. Expose suggestions/insights routes in that surface's controller.

## Configuration

```elixir
config :barkpark, :search_query_blocklist, ["custom", "blocked", "terms"]
```

## Roadmap

Phases 0–8 shipped: `QueryPipeline`, surface settings, golden eval
(`mix search.eval`), federated `GET /w/:workspace_slug/p/:project_slug/v1/search/:dataset`
(flat alias `GET /v1/search/:dataset`), shared `bp-search-intel.js`. Phase 10 also
SHIPPED — `Barkpark.Plugins.Indx.Retriever` behind the `Barkpark.Search.Retriever`
seam, `?engine=indx`. Only Phase 9 (Oban async record, RANGE partitions) is forward
work — triggers in `ROADMAP.md`. Earlier phase-6–10 design notes were removed; recover from git history.

## Phase 7 admin runbook (synonym promotion)

1. **Inspect no-hits** — `GET …/search/:dataset/insights` (or media equivalent). Check `zeroHitRate`, `recoveryRate`, `synonymCandidates`.
2. **Preview** — `GET …/synonyms/preview?q=…&from=…&to=…` returns `{beforeCount, afterCount}` without writing.
3. **Promote** — `POST …/synonyms/promote` with `{from, to}` from a candidate row.
4. **Regression gate** — `mix search.eval --surface documents --dataset pipeline` locally after seeding; CI runs `golden_eval_test.exs`.

Surface settings (Phase 6): `GET/PUT …/search/settings` for `searchableFields`,
`zeroHitStrategy`, `typoPolicy`, `highlightFields`.

## Deprecated

- `media_search_*` table names — migrated to `search_intel_*`

## Code anchors

- `api/lib/barkpark/search/intelligence.ex` — `Barkpark.Search.Intelligence` (incl. `@retention_days`)
- `api/lib/barkpark/search/workers/crystallize.ex` / `workers/prune.ex` — nightly Oban jobs
- `api/config/config.exs` — Oban crontab entries
- `api/lib/barkpark_web/search_intel.ex` — `BarkparkWeb.SearchIntel` (reads `x-bp-search-parent`)
- `api/lib/barkpark/search/query_pipeline.ex` — `Barkpark.Search.QueryPipeline`
