---
'@barkpark/core': patch
---

core: two SDK write guards.

- `createOrReplace()`/`createIfNotExists()` (both the single-op client conveniences and the transaction-builder ops) now accept `Partial<BarkparkDocument> & { _id, _type }` instead of a full `BarkparkDocument`. The runtime guard only ever required `_id` + `_type`, and the server assigns `_rev`/`_createdAt`/`_updatedAt`/`_publishedId`/`_draft` — so the old signature forced `as any` casts and made the documented copy-paste examples fail to typecheck. Pure widening, non-breaking.
- `createWebhook()` (after the existing non-empty check) and `updateWebhook()` (only when `url` is present in the patch) now reject a scheme-less or typo'd delivery URL with `BarkparkValidationError` (field `url`) before any request, mirroring the absolute http(s) guard already used for `projectUrl`. Previously a bad url shipped to the server and the hook silently never fired.
