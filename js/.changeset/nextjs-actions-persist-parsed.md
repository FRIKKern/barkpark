---
'@barkpark/nextjs': patch
---

`defineActions().createDoc` now persists the value RETURNED by `schema.parse(input)`, not the raw input. Previously the parsed result was discarded (parse was called only for its throw-on-invalid side effect), so any Zod transform — `.trim()`, `.toLowerCase()`, `.default()`, `.coerce`, `.transform()` — validated but was silently dropped from the stored document. The transformed value is now the create body, with `_type` re-pinned (Zod strips unknown keys by default, which would otherwise drop the discriminant and trip the create-time `_type` guard). Compat note: if you relied on the previous behaviour of persisting the exact raw input regardless of what your schema returned, documents now carry the schema-normalized form.
