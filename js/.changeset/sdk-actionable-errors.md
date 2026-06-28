---
'@barkpark/core': patch
---

Make two query-builder validation errors actionable — `unknown filter op` now lists the allowed ops, and `invalid order spec` names the valid specs (`_updatedAt:asc|desc`, `_createdAt:asc|desc`), matching the existing `limit`/`offset` errors that already state their range.
