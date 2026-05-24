# Media discovery at scale

How Barkpark thinks about finding assets in a library that may grow to **1M+** items (TIFF, PDF, video, everything). This doc is the guardrail for Media Desk, the v1 search API, and future search-tier work.

**Status:** Active philosophy (2026-05). Implementation is phased; nothing here blocks shipping current fixes.

---

## Two modes: Find vs Pick

| Mode | Job | Must feel | Current surface |
|------|-----|-----------|-----------------|
| **Find** | Reduce 1M → tens–hundreds | Instant (<300ms) | Search box, facet rail, toolbar pills |
| **Pick** | Choose one (or few) from a bounded set | Rich, visual | Grid, filmstrip, inspector |

**Rule:** Never ask users to scroll through the whole library. Browse grids are for **result sets**, not the catalog.

Media Desk v2 is a good **Pick** shell. Scale work prioritises **Find** trust (correct totals, pagination, fast facets) before more inspector polish.

---

## Architecture lanes (dual-track)

We run two tracks in parallel. Ship lane must not violate scale guardrails.

### Ship lane — fix and deploy what we have

- Media Desk v2 on production
- Picker/browser on v1 search (done)
- Honest result counts and pagination in the UI
- Light-theme pass, test-fixture cleanup
- Postgres indexes on hot join/filter paths (cheap wins)

### Scale lane — prepare for 100k–1M

- Dedicated search index (OpenSearch or Meilisearch) — Postgres remains source of truth
- Keyset/cursor pagination in API (replace offset)
- Text extraction pipeline (PDF, optional OCR for TIFF previews)
- Saved searches → virtual collections in UI
- Virtualised grid + bulk actions on **query**, not just loaded rows

**Decision point (not yet made):** OpenSearch (WoodWing parity) vs Meilisearch (faster MVP). Either way, the v1 `/search` response shape stays stable; only the backend engine changes.

---

## Guardrails (every media PR)

1. **Show `total`** — UI must display matching count from API, not `hits.length`.
2. **Page, don't cap** — No silent 500-cap as "the library". Use load-more or infinite scroll wired to `total`.
3. **Facets are AND, values OR** — Match WoodWing/AEM semantics; facet params via `facet.*`, not duplicated in `q`.
4. **Previews ≠ originals** — Grid uses renditions; TIFF/PDF/large files get async preview or honest icons.
5. **No new offset-only APIs** — New list endpoints should design for cursor/keyset even if first impl uses offset internally.
6. **Metadata drives Find** — Prefer indexing title, tags, mime, dates, rights before new grid chrome.

---

## Phased roadmap

| Phase | Focus | Exit criteria |
|-------|--------|---------------|
| **0** (now) | Honest UI + deploy | `total` visible, load-more, prod on v2 |
| **1** | Postgres bridge | Indexes on join + ILIKE paths; keyset API draft |
| **2** | Search tier | Index sync job; facets from search engine |
| **3** | Sophisticated Find | Saved searches, list view, bulk-on-query |
| **4** | Format depth | PDF text, TIFF pyramids, semantic optional |

Phases 0–1 are Ship lane. Phase 2+ is Scale lane but API contracts are designed now so we don't rewrite the Studio twice.

---

## Facet catalog (target)

Prioritise from user interviews; start with what the schema already has:

- **P0:** kind, mime family, status, processing, visibility, date bucket
- **P1:** tags, collection, size bucket, uploader
- **P2:** rights, asset role, colour space (TIFF), page count (PDF)

Keep the sidebar to ~12 facets max; hide empty or low-cardinality facets.

---

## UI shell (Find vs Pick)

Media Desk layout maps directly to the two modes:

| Zone | Mode | Components |
|------|------|------------|
| Left sidebar | **Find** | Kind tabs, Refine facets, Collections shortcuts |
| Toolbar | **Find** | Search, filter pills, Clear all, view toggle (Grid/List) |
| Find bar | **Find** | Match count + hint when filters active |
| Result area | **Pick** | Grid or List (List for PDF/TIFF/metadata-heavy), Load more |
| Filmstrip | **Pick** | Quick scan within loaded page |
| Right inspector | **Pick** | Metadata, governance, share, relations |

**Grid** = visual assets (images, video posters). **List** = dense metadata scan (documents, mixed libraries at scale). Both operate on the same bounded result set — never the full 1M catalog.

Future Phase 3 additions in this shell: saved searches (sidebar), bulk select on query, list column config.

**Shipped in explorer (Phase 0+):** sort control, Format facet, scroll/load-more paging, list headers, `/` to focus search, inspector tags + document previews, session prefs for view/sort.

---

## References

- WoodWing Assets search API: `q`, `start`, `num`, `facets`, `facet.<field>.selection`
- Barkpark implementation: `api/lib/barkpark/media/search.ex`, `bp-asset-explorer.js`
- Smoke: `scripts/media-smoke.sh`

---

## Open questions

1. Primary find scenario: editorial (A), archive/TIFF (B), mixed enterprise (C)?
2. Search tier timing: after Postgres indexes, or in parallel with Phase 0 UI fixes?
3. Single-tenant Hetzner vs multi-tenant — affects index isolation and facet cache strategy.

Record answers in this doc when decided.
