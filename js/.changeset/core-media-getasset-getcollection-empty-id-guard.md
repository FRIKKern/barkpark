---
'@barkpark/core': patch
---

media: guard `getAsset`/`getCollection` against an empty id. Both null-returning reads now call `assertAssetId(id)` first, matching every other media op. Previously an empty/whitespace id made `encodeURIComponent('')` collapse the URL onto the LIST route, so the `data.result ?? data` unwrap returned a list-shaped page object cast as a single `MediaAsset`/`MediaCollection` — a silently wrong 200 instead of an error. An empty id now throws `BarkparkValidationError` before any request; genuinely-missing ids still return `null` on 404 as before.
