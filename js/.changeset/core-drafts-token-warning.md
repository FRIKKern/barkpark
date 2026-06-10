---
"@barkpark/core": patch
---

Warn at config time when `perspective: 'drafts' | 'raw'` is set without a `token`. The server pins anonymous reads to the published perspective, so a tokenless drafts client doesn't error — it silently reads published documents. The warning makes that degrade loud; pass `token` to read drafts.
