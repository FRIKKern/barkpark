---
"@barkpark/core": patch
"@barkpark/nextjs": patch
---

fix(core): tolerate Phoenix's wrapped read envelope

`@barkpark/core`'s `query()` and `doc()` previously read the response body
as if it were flat — `data.documents` for `docs(...)` and `data` directly
for `doc(...)`. Phoenix's `query_controller`, however, wraps every read
in `{ result, syncTags, ms, etag, schemaHash }` whenever
`barkpark_filterresponse=true` (the production default), so both helpers
silently returned `[]` / the envelope object instead of the actual
document(s).

The unwrap is now tolerant of either shape:

- `docs(...)` reads `data.result?.documents ?? data.documents ?? []`
- `doc(...)` unwraps `data.result` when present, otherwise treats `data`
  as the doc body.

`@barkpark/nextjs` ships a transitive patch bump because it re-exports
`@barkpark/core` and inherits the fix end-to-end. The `web/lib/barkpark-shim.ts`
workaround in consuming apps can be deleted once they upgrade to
`1.0.0-preview.3`.
