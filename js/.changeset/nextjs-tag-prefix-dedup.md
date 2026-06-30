---
'@barkpark/nextjs': patch
---

Internal: the cache-tag namespace format (`bp:ws:<ws>:p:<project>:ds:<dataset>` scoped / `bp:ds:<dataset>` flat) was duplicated across three sites that must agree exactly — the write side (`defineActions` fan-out), the read side (`server` fetch tagging), and the webhook revalidate fallback. Extracted to a single `formatTagPrefix` so the three can no longer drift apart (a drift would silently stop writes/webhooks from invalidating the matching cached reads). No behavior change.
