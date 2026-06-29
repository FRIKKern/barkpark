---
'@barkpark/core': patch
---

Export `QueryEnvelope` — the current query-response envelope type. Its deprecated, being-removed sibling `ReadEnvelope` was already exported; the current type was not, so consumers typing a raw query response (e.g. via `fetchRaw`) couldn't name it.
