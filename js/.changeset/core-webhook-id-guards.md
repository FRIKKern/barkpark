---
'@barkpark/core': patch
---

core: `updateWebhook()`/`deleteWebhook()` now reject an empty id with `BarkparkValidationError` (field `id`) before any request, matching the guard every other core write op already has. Previously an empty id collapsed the URL to the collection route (trailing empty segment), firing a PUT/DELETE at the wrong resource — an opaque 404/405 (or a stray collection DELETE). `getWebhook` stays unguarded (null-returning read, consistent with `getAsset`).
