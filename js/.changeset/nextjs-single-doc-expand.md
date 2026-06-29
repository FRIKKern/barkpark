---
'@barkpark/nextjs': minor
---

`barkparkFetch` single-document fetches (`{ type, id }`) now accept `expand` (inline reference fields) and `fields` (projection) — mirroring `bp.doc(id, { expand, fields })`. Previously only the list path could expand/project; a server component fetching one document by id and inlining a reference had to fall back to a list query.
