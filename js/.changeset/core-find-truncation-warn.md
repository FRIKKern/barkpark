---
'@barkpark/core': patch
---

`docs(type).find()` no longer truncates silently. It returns one server page (100 rows by default), and its documentation now says so. A `find()` without `.limit()` that leaves documents behind logs a one-time warning per type pointing at `.limit(n)` (max 1000) and `.findPage()`.
