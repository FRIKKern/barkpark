---
'@barkpark/core': minor
---

Add `.count()` to the docs query builder — `bp.docs('post').eq('status','published').count()` returns the total number of matching documents (ignoring limit/offset), via the server's `?count=true`. The paginator total to pair with `.find()`.
