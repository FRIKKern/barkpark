---
'@barkpark/nextjs': patch
---

`defineActions().createDoc` now fails closed on a missing/empty `_type` and on an unsound `schema.parse()` result. An empty `_type` (reachable from untyped form/JSON input) previously skipped schema validation and fired a garbage `bp:ds:<ds>:type:` revalidate tag that matched no read tag, silently losing the intended `:type:<type>` invalidation — it now throws `BarkparkValidationError` before touching core or `revalidateTag`. Separately, a schema whose top-level `.parse()` returns a primitive/array (via `.transform()` / `z.string()`) would corrupt the create body when spread (`'hi'` → `{0:'h',1:'i'}`); the parse result is now guarded to be a plain object.
