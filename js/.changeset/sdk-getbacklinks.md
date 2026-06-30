---
'@barkpark/core': minor
---

Added `client.getBacklinks(id)` — the documents that reference a given doc (inbound references / backlinks, Sanity's `*[references($id)]`). Wraps `GET /v1/data/backlinks/:dataset/:id` (shipped server-side in #502), returning `{ backlinks: [{ from_doc_id, title, type, kind }], count }`. The server is fail-closed: referencing sources the caller can't see are never returned. New types: `Backlink`, `BacklinksResult`, `BacklinksOptions`.
