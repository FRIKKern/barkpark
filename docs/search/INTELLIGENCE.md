# Search Intelligence (Barkpark core)

Surface-agnostic search analytics, crystallization, and improvement signals.
Product surfaces (Media DAM, document search) plug in via thin adapters.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Surface adapter (e.g. Barkpark.Media.SearchIntelligence)  │
│  — translates native API params → core context map          │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Barkpark.Search.Intelligence                                 │
│  record · suggestions · insights · prune                      │
├───────────────────────────────────────────────────────────────┤
│  Barkpark.Search.Sanitizer   quality gate (profanity, spam)   │
│  Barkpark.Search.Crystallizer day / week / month rollups      │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  Postgres `search_intel_*` tables                             │
│  keyed by `surface` + `scope`                                 │
└───────────────────────────────────────────────────────────────┘
```

## Key concepts

| Term | Meaning | Media DAM example |
|------|---------|-------------------|
| **surface** | Product area | `"media"` |
| **scope** | Tenant partition | `"production"` (dataset) |
| **context** | Normalized search state | `%{query, filters, offset}` |
| **crystal** | Day/week/month aggregate | Popular query + filter fingerprint |
| **merge pattern** | Refinement transition | `zero_to_hit`, `facet_add` |

## Core modules

| Module | Role |
|--------|------|
| `Barkpark.Search.Intelligence` | Public core API |
| `Barkpark.Search.Sanitizer` | Query quality gate |
| `Barkpark.Search.Crystallizer` | Rollups + merge detection |
| `Barkpark.Search.Event` | Raw event schema |
| `Barkpark.Search.Crystal` | Crystallized stats schema |
| `Barkpark.Search.MergePattern` | Transition pattern schema |
| `Barkpark.Search.Workers.Crystallize` | Nightly Oban job (03:30 UTC) |
| `Barkpark.Search.Workers.Prune` | Raw event prune (04:00 UTC) |

## Media DAM adapter

`Barkpark.Media.SearchIntelligence` is the only module Media Desk / v1 media API should call.

```elixir
SearchIntelligence.record("production", conn_params, total, ms,
  actor_key: "...",
  parent_event_id: "...",
  source: "explorer"
)
```

WoodWing-style facet params are translated via `MediaSearchParams` inside the adapter.

## Documents adapter

`Barkpark.Content.SearchIntelligence` wraps `/w/:workspace_slug/p/:project_slug/v1/data/search/:dataset` with `surface: "documents"`.

```elixir
SearchIntelligence.record("production", params, count, ms,
  actor_key: "...",
  source: "studio-picker"
)
```

Filters captured: `type`, `perspective` (`published` | `drafts` | `raw`).

## HTTP (documents surface)

Endpoints are addressed under the workspace + project prefix (the canonical form). The flat `/v1/data/search/*` paths remain as the `Default`/`Default` back-compat alias — see `docs/api-v1.md` §1a.

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `GET /w/:workspace_slug/p/:project_slug/v1/data/search/:dataset` | optional | Title search (+ `searchEventId`) |
| `GET /w/:workspace_slug/p/:project_slug/v1/data/search/:dataset/suggestions` | optional | Recent / popular / nohits |
| `GET /w/:workspace_slug/p/:project_slug/v1/data/search/:dataset/insights` | admin | Crystals, merge patterns, hints |

> Flat alias: `GET /v1/data/search/:dataset[/suggestions|/insights]` → resolves the `Default` workspace + project.

## HTTP (media surface)

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `GET /w/:workspace_slug/p/:project_slug/v1/media/:dataset/search/suggestions` | optional | Recent / popular / nohits |
| `GET /w/:workspace_slug/p/:project_slug/v1/media/:dataset/search/insights` | admin | Crystals, merge patterns, hints |

> Flat alias: `GET /v1/media/:dataset/search/[suggestions|insights]` → resolves the `Default` workspace + project.

Headers for lineage (all surfaces):

- `X-BP-Search-Client` — session actor
- `X-BP-Search-Parent` — previous event id (refinement chain)
- `X-BP-Search-Source` — `explorer`, `picker`, `studio-picker`, `api`

Shared conn helpers: `BarkparkWeb.SearchIntel`.

## Adding a new surface

1. Pick a `surface` string (e.g. `"documents"`).
2. Implement an adapter module that builds `%{query, filters, offset}` from native params.
3. Call `Barkpark.Search.Intelligence.record/6` — no new tables required.
4. Expose suggestions/insights routes in that surface's controller.

## Configuration

```elixir
# config/config.exs or runtime.exs
config :barkpark, :search_query_blocklist, ["custom", "blocked", "terms"]
```

## Deprecated

- `Barkpark.Media.SearchAnalytics` — delegates to `Media.SearchIntelligence`
- `media_search_*` table names — migrated to `search_intel_*`
