# Search Intelligence Roadmap

Phased plan derived from Algolia, Typesense, Postgres, and Elixir best-practice research (May 2026). Builds on the shipped core (`Barkpark.Search.*`, `search_intel_*`, media + documents surfaces).

**Principle:** Postgres remembers and explains; search engines (today: ILIKE/pg_trgm) retrieve. Do not add Algolia/Typesense as a dependency until Postgres search latency fails SLA.

---

## Current state (shipped)

| Layer | Status |
|-------|--------|
| Core API | `Intelligence.record/suggest/insights/prune` |
| Surfaces | `media`, `documents` adapters |
| Suggestions | recent / popular / nohits |
| Crystallization | day / week / month + merge patterns |
| Quality gate | `Sanitizer` + `__quality__` crystal |
| Client lineage | `X-BP-Search-*`, `searchEventId`, Studio pickers wired |
| Retention | 90-day raw events; crystals indefinite |

---

## Phase 0 — Correctness (P0, ~1 day)

**Why:** Elixir + Postgres research flagged a real multi-surface collision risk.

| Task | Detail |
|------|--------|
| Fix unique indexes | Add `surface` to `search_intel_crystals` and `search_intel_merge_patterns` unique constraints (currently `scope, period, …` only — media + documents on `production` can collide) |
| Suggest indexes | Partial index `(surface, scope, actor_key, inserted_at DESC) WHERE quality = 'accepted'`; prefix index on `query_normalized text_pattern_ops` |
| trgm alignment | GIN on `query_normalized` (not just raw `query`) |
| Tests | Surface-isolated crystal upsert; merge_pattern upsert across two surfaces |

**Exit:** Migration runs clean; test proves documents + media crystals coexist on same scope.

---

## Phase 1 — Suggest read path (P0, ~2 days)

**Why:** Algolia/Typesense serve popular from aggregates; Barkpark re-scans 30 days of raw events on every autocomplete request.

| Task | Detail |
|------|--------|
| Popular from crystals | Roll up last 30 days of **day** crystals for `popular` and `nohits` buckets |
| Keep recent on raw | Per-`actor_key` recent stays on events (Algolia has no equivalent; Typesense uses user id) |
| `min_search_count` | Hide popular suggestions with count < 3 (Algolia `minPopularity` analog) |
| Result validation | At crystallize time, optionally re-run search; drop popular rows that are now zero-hit (Algolia `min_hits`) |
| `X-BP-Search-Disable` | Header or param to skip recording (Typesense `enable_analytics: false`, Algolia `analytics: false`) |
| Smoke/tests | Suggestions still work after raw events older than 30d are pruned |

**Exit:** `/suggestions` p95 stable as event volume grows; popular survives prune.

---

## Phase 2 — Click & CTR events (P1, ~3 days)

**Why:** Algolia Insights + Typesense `counter` rules; biggest gap vs industry maturity.

| Task | Detail |
|------|--------|
| Event type column | `event_type`: `search` \| `click` \| `select` (default `search`) |
| Click payload | `object_id`, `position`, `query_event_id` (FK to originating search) |
| HTTP endpoint | `POST …/search/interaction` or extend existing routes with click body |
| JS | Explorer + pickers send click on result select; chain via `searchEventId` |
| Crystals | Add `click_count`, `ctr` to crystal rollups |
| Insights | Expose CTR in `/insights`; hint when CTR low but volume high |

**Exit:** Admin insights show CTR per top query; click linked to search event.

---

## Phase 3 — Quality, segmentation, debounce (P1, ~2 days)

**Why:** Algolia `analyticsTags`, banned expressions, Typesense 4s debounce.

| Task | Detail |
|------|--------|
| `tags` on events | JSON array or reuse `source` + new `tags[]` for segmentation (studio, api, test) |
| Exclude test traffic | `source: test` / header disable excluded from popular crystals |
| Stricter suggest gate | `min_letters: 4` for suggestions (keep record at 2 for analytics) |
| Regex exclude list | Config `:search_query_exclude_patterns` (Algolia banned expressions) |
| Debounced record | Client: only record search after 300–400ms idle OR on Enter (Typesense 4s analog — use shorter for CMS) |
| Telemetry | `[:barkpark, :search, :intel, :record]` with `:ok`, `:skipped`, `:rejected`, `:error` |

**Exit:** Smoke tests do not pollute popular; Grafana-ready telemetry events.

---

## Phase 4 — Query understanding loop (P2, ~1 week)

**Why:** Algolia synonyms + Typesense nohits → synonym discovery; Barkpark already has hints.

| Task | Detail |
|------|--------|
| `search_synonyms` table | `surface`, `scope`, `from`, `to`, `kind` (one_way \| alt_correction), `source` (manual \| auto) |
| Admin UI | Studio or API: promote nohit crystal → synonym candidate |
| Auto candidates | Export `zero_to_hit` merge patterns as synonym suggestions |
| Apply in search | Documents FTS + media search consult synonym map before query |
| Trending | `search_count_delta` on week crystals (Algolia Recommend velocity lite) |

**Exit:** Top nohit query can be promoted to synonym and improves results without redeploy.

---

## Phase 5 — Content search quality (P2, ~1 week)

**Why:** Postgres research; documents use ILIKE today.

| Task | Detail |
|------|--------|
| FTS on documents | Generated `tsvector` on title + slug; GIN index; `ts_rank` in `Content.search_documents` |
| Hybrid fallback | If FTS returns 0, fall back to pg_trgm `%` similarity (typo layer) |
| Media search | Evaluate ILIKE vs trgm on filename/title at current corpus size |
| ParadeDB pilot | Only if >500k rows or fuzzy p95 > 100ms (defer otherwise) |

**Exit:** Document search ranked; intelligence layer unchanged.

---

## Phase 6 — Scale & ops (P2, as volume demands)

**Why:** Postgres research retention/partitioning guidance.

| Task | Detail |
|------|--------|
| Async record | Oban `:search_intel` queue insert; search never waits on DB |
| Crystal retention | Day crystals 90d; week/month 2y (document policy) |
| Partition events | Monthly RANGE on `inserted_at`; DROP partition instead of DELETE prune |
| SQL crystallize | Move heavy day aggregation to SQL `INSERT…SELECT` when >100k events/day |
| Optional session table | `search_intel_session_recent` if autocomplete QPS hot |
| Shared JS module | `bp-search-intel.js` — client id, headers, debounce (dedupe 3 pickers) |

**Exit:** Prune is O(1) partition drop; crystallize bounded memory.

---

## Phase 7 — Optional external engine (P3, only if needed)

**Why:** Typesense research — engine for retrieval, Postgres for intelligence.

| Trigger | Action |
|---------|--------|
| Need sub-50ms fuzzy faceted search at scale | Typesense collection per surface; presets per UI |
| Do **not** move analytics to Typesense | Mirror top crystals → Typesense `popular_queries` collection only if CDN autocomplete needs it |
| Skip Algolia SaaS | Unless enterprise SLA requires it |

---

## What we deliberately skip

| Feature | Reason |
|---------|--------|
| Algolia Recommend ML | No co-purchase graph; CMS not storefront |
| Personalized suggestions | Needs click volume + user profiles |
| Full Rules / merchandising engine | CMS editorial workflow differs |
| Separate suggestions index rebuild | Crystals + Postgres sufficient |
| Redis for recent | Actor-key query fine until high QPS |

---

## Suggested execution order

```
Phase 0 ──► Phase 1 ──► Phase 2
                │
                ├──► Phase 3 (parallel with 2)
                │
Phase 4 ◄── after Phase 2 (clicks improve synonym quality)
Phase 5 ◄── independent; parallel after Phase 0
Phase 6 ◄── when events > 5M or prune > 30s
Phase 7 ◄── only on search latency pain
```

---

## Success metrics

| Metric | Target |
|--------|--------|
| Suggest p95 | < 50ms at 100k events/scope |
| Popular accuracy | Zero stale zero-hit terms in top 10 |
| CTR coverage | >50% of searches have click tracking (Phase 2+) |
| Nohit rate | Visible in insights; downward trend after synonym loop |
| Multi-surface | Zero crystal collisions across media/documents |

---

## References

- `docs/search/INTELLIGENCE.md` — architecture
- `docs/media/DISCOVERY.md` — media search surface
- Research swarm (May 2026): Algolia, Typesense, Postgres, Elixir reports
