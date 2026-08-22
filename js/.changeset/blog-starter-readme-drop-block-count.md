---
'create-barkpark-app': patch
---

blog-starter README: drop the fabricated PortableDoc block COUNT. The scaffolded README advertised the renderer as handling "(42 block types)". That number is stale — `REGISTERED_TYPES.length` is 70 at runtime (60 canonical types, each with one Elixir golden fixture, plus 10 authoring-drift aliases; `registry.ts:33-38` says so itself) — and `42` dates from 2026-05.

The count is DELETED rather than corrected to 60. Correcting it re-arms the same rot on the next merge and collides with sibling work retiring rival counts elsewhere; the surviving claim — the canonical `@barkpark/react` `PortableDoc`, never a fork — is fully true and needs no number to carry it.

Docs-only: the scaffolded app's behaviour, deps and generated code are unchanged. The same edit lands on the control plane's vendored copy (`cloud/priv/templates/blog-starter/README.md`), which the `app_files_drift_test` pins byte-for-byte against this one.
