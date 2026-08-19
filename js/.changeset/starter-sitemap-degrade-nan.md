---
'create-barkpark-app': patch
---

Harden both starter template sitemaps (`blog-starter` and `website-starter` `app/sitemap.ts`). The `getDocs` await is now wrapped in try/catch so an API 500, network failure, or timeout during build or crawl degrades to a valid sitemap (website returns its static routes, blog returns a minimal home-route entry) instead of throwing and breaking the build. The `_updatedAt` date helper now returns `undefined` for an unparseable value, so a malformed timestamp can no longer produce an Invalid Date that `RangeError`s when Next serializes `lastModified` via `.toISOString()`.
