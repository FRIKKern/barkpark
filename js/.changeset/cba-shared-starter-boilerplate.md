---
'create-barkpark-app': patch
---

The 16 framework files blog-starter and website-starter double-authored now live ONCE, in `templates/_shared/`, and the scaffolder composes them under whichever starter you pick. `_gitignore`, `app/api/barkpark/webhook/route.ts`, `app/error.tsx`, `app/globals.css`, `app/loading.tsx`, `app/not-found.tsx`, `app/robots.ts`, `barkpark.config.ts.tmpl`, `docker-compose.yml`, `docker-compose.override.yml.example`, `lib/format-date.ts`, `lib/resolve-server-token.ts`, `next.config.mjs`, `package.json.tmpl`, `postcss.config.js` and `tsconfig.json` were byte-identical in both starters, so every ordinary fix had to be applied twice or the two starters silently diverged.

Nothing changes for a generated app. Composition is build-time: `_shared` is laid down first and the starter tree is copied OVER it (so a starter can always take a file back by re-adding it under its own dir), and the result is a plain self-contained tree — no `_shared` directory in the output and no file in it that names one. Files that differ between the starters — `app/layout.tsx`, `app/page.tsx`, `app/sitemap.ts`, `lib/barkpark.ts`, `lib/csp.ts`, `middleware.ts`, `tailwind.config.ts`, `.env.example`, `README.md`, the schemas and the seeds — stay in their starter, unchanged.
