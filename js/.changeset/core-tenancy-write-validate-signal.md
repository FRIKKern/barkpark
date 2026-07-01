---
'@barkpark/core': minor
---

`createWorkspace` and `createProject` now client-side validate `attrs.name` and accept an `AbortSignal`, matching their sibling tenancy calls. Passing `{}` or `{ name: '' }` now fast-fails with a field-tagged `BarkparkValidationError` (`field: 'name'`) instead of paying a network round-trip for a raw server 422 — the same immediate feedback every other write path already gives. Both also gained a trailing `opts?: { signal?: AbortSignal }` argument (their read siblings already had one), so a create can be aborted like any other request.
