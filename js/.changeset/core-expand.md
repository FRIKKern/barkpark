---
'@barkpark/core': minor
---

Add `.expand()` to the query builder — inline reference fields with their full documents in one request (depth 1), e.g. `bp.docs('post').expand(['author', 'tags']).find()`. The API supported `?expand=` but the SDK didn't expose it, forcing N+1 manual resolution. Additive.
