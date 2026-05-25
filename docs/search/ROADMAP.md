# Search Intelligence Roadmap

Phased plan derived from Algolia, Typesense, Sanity, WoodWing, Postgres, and relevance-engineering research (May 2026). Builds on `Barkpark.Search.*`, `search_intel_*`, media + documents surfaces.

**Principle:** Postgres remembers and explains; search engines retrieve. No Algolia/Typesense dependency until Postgres search latency fails SLA.

**Detailed plan for next phases:** [`PLAN-PHASES-6-10.md`](PLAN-PHASES-6-10.md)

---

## Shipped (Phases 0–5 ✓)

| Phase | Summary | Commit / prod |
|-------|---------|---------------|
| **0** | Surface-safe unique indexes, suggest indexes, trgm on `query_normalized` | `cf5de75` |
| **1** | Crystal-backed popular/nohits, `min_search_count`, `X-BP-Search-Disable` | `cf5de75` |
| **2** | Click/select events, CTR on crystals, interaction API, JS wiring | `9052f95` |
| **3** | Tags, test exclusion, 4-char suggest gate, exclude patterns, debounced record, telemetry | `69ce1bb` |
| **4** | `search_synonyms`, admin CRUD, auto candidates, apply in search, `searchCountDelta` | `cdf6597` |
| **5** | Document `search_vector` FTS + trgm hybrid; media synonym expansion | `cdf6597` |

| Layer | Status |
|-------|--------|
| Core API | `Intelligence.record/suggest/insights/prune/record_interaction` |
| Surfaces | `media`, `documents` adapters |
| Synonyms | `Barkpark.Search.Synonyms` + admin routes |
| Suggestions | recent / popular / nohits |
| Crystallization | day / week / month + merge patterns |
| Quality gate | `Sanitizer` + `__quality__` crystal |
| Client lineage | `X-BP-Search-*`, `searchEventId`, debounce, Studio pickers |
| Retention | 90-day raw events; crystals indefinite |

---

## Up next (Phases 6–10)

| Phase | Focus | Effort | Doc |
|-------|-------|--------|-----|
| **6** | Relevance: `QueryPipeline`, field weights, query parse, zero-hit recovery, highlights | ~2 wk | [PLAN §6](PLAN-PHASES-6-10.md#phase-6--relevance-engineering-p1-2-weeks) |
| **7** | Intelligence product: golden eval harness, synonym evidence, promote/preview, richer insights | ~2 wk | [PLAN §7](PLAN-PHASES-6-10.md#phase-7--intelligence-productization-p1-2-weeks) |
| **8** | Unified discovery: federated search, cursor pagination, `bp-search-intel.js`, ⌘K | ~1.5 wk | [PLAN §8](PLAN-PHASES-6-10.md#phase-8--unified-discovery-p2-15-weeks) |
| **9** | Scale: async record, partitions, SQL crystallize | trigger-based | [PLAN §9](PLAN-PHASES-6-10.md#phase-9--scale--ops-p2-trigger-based) |
| **10** | Optional Typesense retriever (intelligence stays Postgres) | pain-gated | [PLAN §10](PLAN-PHASES-6-10.md#phase-10--optional-external-retriever-p3-pain-gated) |

---

## Phase archive (0–5 detail)

<details>
<summary>Phase 0 — Correctness (shipped)</summary>

- Fix unique indexes with `surface`
- Suggest indexes; trgm on `query_normalized`
- Surface-isolation tests
</details>

<details>
<summary>Phase 1 — Suggest read path (shipped)</summary>

- Popular/nohits from day crystals
- `min_search_count: 3`
- `X-BP-Search-Disable`
</details>

<details>
<summary>Phase 2 — Click & CTR (shipped)</summary>

- `event_type` click/select
- `POST …/interaction`
- Crystal `click_count`, `ctr`
</details>

<details>
<summary>Phase 3 — Quality & segmentation (shipped)</summary>

- Event `tags[]`, test exclusion
- 4-letter suggest prefix
- Exclude patterns, debounced record, telemetry
</details>

<details>
<summary>Phase 4 — Synonym loop (shipped)</summary>

- `search_synonyms` table
- Admin CRUD, `synonymCandidates`, apply at query time
- `searchCountDelta` on week crystals
</details>

<details>
<summary>Phase 5 — Document FTS (shipped)</summary>

- Generated `search_vector` on title
- Hybrid FTS + ILIKE + trgm
</details>

---

## Suggested execution order

```
[SHIPPED] Phase 0 ──► 1 ──► 2 ──► 3 ──► 4 ──► 5

[NEXT]    Phase 6 (QueryPipeline) ──► 7 (eval + promote) ──► 8 (federated + JS)

[LATER]   Phase 9 when events > 5M or prune > 30s
          Phase 10 only on search latency pain
```

---

## Success metrics

| Metric | Target |
|--------|--------|
| Suggest p95 | < 50ms at 100k events/scope |
| Popular accuracy | Zero stale zero-hit terms in top 10 |
| CTR coverage | >60% searches with click tracking (Phase 7+) |
| Nohit rate | Downward trend after synonym + recovery loop |
| Golden eval | No NDCG regression on ranking PRs (Phase 7+) |
| Multi-surface | Zero crystal collisions |

---

## What we deliberately skip

| Feature | Reason |
|---------|--------|
| Algolia Recommend ML | No co-purchase graph; CMS not storefront |
| Personalized suggestions | Needs click volume + user profiles |
| Full Rules / merchandising engine | CMS editorial workflow differs |
| Algolia SaaS | Postgres sufficient until Phase 10 trigger |
| Redis for recent | Actor-key query fine until Phase 9 |

---

## References

- [`PLAN-PHASES-6-10.md`](PLAN-PHASES-6-10.md) — detailed Phases 6–10
- [`INTELLIGENCE.md`](INTELLIGENCE.md) — architecture
- `docs/media/DISCOVERY.md` — media search surface
