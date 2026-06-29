---
'@barkpark/core': minor
---

Add `bp.search(q, opts?)` — full-text search across the dataset (`GET /v1/data/search`), returning `{ documents, count, query, highlights?, correctedTo }`. Options: `limit`, `engine` (`postgres` | `indx`), `signal`. The endpoint (and the `bp` CLI) already supported search; the SDK now exposes it. Exports `SearchOptions` / `SearchResult` types.
