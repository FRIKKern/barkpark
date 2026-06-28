---
'create-barkpark-app': patch
---

Fix the website-starter `getDocBySlug` helper (same bug as the blog-starter): it queried `?slug=<slug>`, which the query API ignores, so post detail pages rendered the first document regardless of slug. Now filters server-side on `slug.current` and matches client-side as a safety net.
