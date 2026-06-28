---
'create-barkpark-app': patch
---

Correct the webhook signature description in both starter READMEs: it now matches the shipped wire contract — the combined `t=<unix>,v1=<hex>` header, HMAC-SHA256 over `<timestamp>.<rawBody>` (was the outdated `v1=<hex>` over the raw body).
