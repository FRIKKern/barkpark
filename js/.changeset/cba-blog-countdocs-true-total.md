---
'create-barkpark-app': patch
---

The blog-starter home paginates again. `countDocs` read the query envelope's `count`, which is the size of the page (1 for a `limit: 1` read), as the corpus total. Every blog therefore rendered one page with no page links, and `?page=N` clamped back to page 1. `countDocs` now asks the SDK's `count()`, which reads the `?count=true` total.
