---
"@barkpark/codegen": patch
---

Three fixture shapes that used to emit TypeScript failing at the consumer's `tsc` now fail codegen itself, loudly and locatably: duplicate schema names (including names that collide only after identifier sanitising), a field named `_type`, and any field named after a server-reserved system key (`_id`, `_rev`, `_draft`, `_publishedId`, `_createdAt`, `_updatedAt`). All three are unreachable from the live API (the server rejects reserved keys) and arrive only via hand-authored `--from` fixtures — belt-and-suspenders, refused before a byte is written.
