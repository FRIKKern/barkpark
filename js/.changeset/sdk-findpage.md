---
'@barkpark/core': minor
---

Add `.findPage()` to the docs query builder — returns the page **and** the total match count in a single `?count=true` request (`{ documents, total, count, limit, offset }`), the efficient pagination shape. Exports the `QueryPage<T>` type. Use `.find()` when you don't need the total, `.count()` for the total alone.
