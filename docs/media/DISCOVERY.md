<!-- doc-tier: agent | canonical-for: media-discovery-philosophy | budget: 400tok -->
# Media discovery — Find vs Pick

**Status:** active philosophy (2026-05). Implementation phased; nothing here blocks current fixes.

## The two modes

| Mode | Job | Must feel | Current surface |
|---|---|---|---|
| **Find** | Reduce 1M → tens–hundreds | Instant (<300ms) | Search box, facet rail, toolbar pills |
| **Pick** | Choose one or few from a bounded set | Rich, visual | Grid, filmstrip, inspector |

**Rule: never ask users to scroll the whole library.** Browse grids are for **result sets**, not the catalog. Media Desk v2 is a good Pick shell. Scale work prioritises Find trust (correct totals, fast facets) before more inspector polish.

## OpenSearch vs Meilisearch — decision pending

**Decision point (not yet made):** OpenSearch (WoodWing parity) vs Meilisearch (faster MVP). Either way, the v1 `/search` response shape stays stable; only the backend engine changes.

Postgres remains source of truth regardless.

## Guardrails (every media PR)

1. **Show `total`** — UI must display matching count from API, not `hits.length`.
2. **Page, don't cap** — No silent 500-cap as "the library". Use load-more or infinite scroll wired to `total`.
3. **Facets are AND, values OR** — Match WoodWing/AEM semantics.
4. **Previews ≠ originals** — Grid uses renditions; TIFF/PDF get async preview or honest icons.
5. **No new offset-only APIs** — Design for cursor/keyset even if first impl uses offset.
6. **Metadata drives Find** — Index title, tags, mime, dates, rights before new grid chrome.

## Search analytics

Analytics ops contract lives in `docs/search/INTELLIGENCE.md`. Short form: crystallizer at 03:30 UTC, prune raw events at 04:00 UTC, 90-day retention, `X-BP-Search-Parent` lineage header.

## Phased roadmap

| Phase | Focus |
|---|---|
| 0 (now) | Honest UI: `total` visible, load-more, prod on v2 |
| 1 | Postgres bridge: indexes + keyset API draft |
| 2 | Search tier: index sync, facets from engine |
| 3 | Sophisticated Find: saved searches, bulk-on-query |
| 4 | Format depth: PDF text, TIFF pyramids, semantic optional |

## Code anchors

- `api/lib/barkpark/media/delivery/search.ex` — faceted search over media_files (+ `api/lib/barkpark/search/media_intelligence.ex` for the DAM adapter)
- `api/priv/static/assets/bp-asset-explorer.js` — explorer component
- `scripts/media-smoke.sh` — smoke test
