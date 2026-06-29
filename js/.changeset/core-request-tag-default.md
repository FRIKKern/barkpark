---
'@barkpark/core': minor
---

Requests now send the documented `X-Barkpark-Request-Tag: bp-<uuid>` observability header by default (ADR-010) — previously `requestTagPrefix` defaulted to `''` despite the docs claiming `'bp'`, so tagging was silently off. Set `requestTagPrefix: ''` to opt out, or a custom string for a different prefix.
