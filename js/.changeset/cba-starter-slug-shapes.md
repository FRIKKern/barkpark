---
'create-barkpark-app': patch
---

The blog and website starters now read a document's slug in either shape it is stored in. The Barkpark Studio stores a plain string; the seeds store `{ current }`. Before, a post slugged in the Studio linked by its id, was missing from `sitemap.xml`, and 404'd at its own slug URL. Links, the sitemap and `getDocBySlug` now go through one shared `slugOf()`.
