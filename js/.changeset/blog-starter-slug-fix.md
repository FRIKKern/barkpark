---
'create-barkpark-app': patch
---

Fix the blog-starter `getDocBySlug` helper: it queried `?slug=<slug>`, which the query API ignores (it reads `filter=field=value`, not bare params), so every post/tag detail page rendered the first document regardless of slug. Now filters server-side on `slug.current` and matches client-side as a safety net.
