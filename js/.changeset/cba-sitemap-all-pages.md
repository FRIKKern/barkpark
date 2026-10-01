---
'create-barkpark-app': patch
---

Both starters' `sitemap.xml` now list every post, and the blog's authors and tags, instead of the first 100. `getDocs` reads one page of the query route and dropped its `hasMore`. A new `getAllDocs` follows `hasMore` page by page, up to the 50,000-URL sitemap cap.
