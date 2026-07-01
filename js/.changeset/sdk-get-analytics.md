---
'@barkpark/core': minor
---

**Added:** `client.getAnalytics()` — fetch a dataset's content-stats overview (`GET /v1/data/analytics/:dataset`): total document count, per-type published/draft breakdown, and recent activity. A token-required scoped read (same tier as export / history / revision) that the SDK previously had no method for. New `DatasetAnalytics` + `DocumentTypeStats` types.
