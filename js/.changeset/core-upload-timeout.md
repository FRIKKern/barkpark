---
'@barkpark/core': minor
---

`uploadAsset` now defaults to a 120s timeout (vs the 60s write default — uploads run longer) and accepts a `timeoutMs` override in `UploadOptions` for large transfers (`0` disables). Previously a large upload was stuck at the 60s write default with no way to extend it.
