---
'@barkpark/core': patch
---

Surface the API error envelope's `hint` field on thrown errors as `error.hint`, so JS consumers get the same fix-suggestion the `bp` CLI prints and the API returns.
