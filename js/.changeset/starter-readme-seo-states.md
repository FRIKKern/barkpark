---
'create-barkpark-app': patch
---

Both starter READMEs now document the SEO files (per-page metadata, `sitemap.ts`, `robots.ts`, `metadataBase`) and graceful-state files (`not-found.tsx`, `error.tsx`, `loading.tsx`) added earlier, and — importantly — call out `NEXT_PUBLIC_SITE_URL` in the Deploy section (without it the sitemap/OpenGraph/canonical URLs emit `localhost` in production). Closes the doc-currency gap so a scaffolded user discovers these features and configures them for deploy.
