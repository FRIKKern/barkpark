---
'create-barkpark-app': patch
---

Both starters now ship SEO discovery files: `app/sitemap.ts` and `app/robots.ts`, plus a `metadataBase` on the root layout so the per-page OpenGraph/canonical URLs resolve to absolute ones. The sitemap lists the home route and every content route (blog: posts + authors + tags; website: posts + the static pages). A new `NEXT_PUBLIC_SITE_URL` env var (documented in `.env.example`, localhost fallback in dev) drives the absolute URLs. Completes the per-page metadata added earlier so the starters are search-engine-ready out of the box.
