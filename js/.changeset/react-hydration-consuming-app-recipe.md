---
'@barkpark/react': patch
---

README: document a real consuming-app recipe for `@barkpark/react/client`'s `hydratePortableDoc` — a Next.js `'use client'` island (mirroring the shipped blog-starter's `portable-doc-surface.tsx`) and a framework-free Astro `<script>` island, covering the server/client boundary, why nothing needs cleanup, error-swallow behavior, idempotency (no double hydration), and the CSP consequence of `mermaid` (`'unsafe-eval'` in `script-src`; no extra host allowlist needed when bundled via `import()` rather than a CDN `<script>`).

Both recipes are pinned, not prose-only: `tests/docs-examples/nextjs-hydration-recipe.tsx` and `tests/docs-examples/astro-hydration-recipe.ts` are real TypeScript, type-checked by the package's existing `typecheck` script (`tsc --noEmit`) against the actual public exports on every change — a renamed export or a changed `hydratePortableDoc` signature breaks the build here before the README snippet goes silently stale. Neither file matches vitest's `.test.`/`.spec.` include glob, so `pnpm test` is unaffected; `pnpm lint` and `pnpm typecheck` both pass clean on the new files.

Docs + a doc-pinning test only — no runtime code changed.
