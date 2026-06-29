---
'@barkpark/core': patch
---

`transaction.commit({ timeoutMs })` and `patch().commit({ timeoutMs })` now actually apply the per-call timeout — previously `CommitOptions.timeoutMs` (documented as a per-call override) was dropped, so commit fell back to the default write timeout regardless.
