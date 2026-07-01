---
'create-barkpark-app': patch
---

Both starters now ship the App Router graceful-state files: `not-found.tsx` (a branded 404 — the post/author/tag pages already call `notFound()`, which previously rendered Next's unstyled default), `error.tsx` (a segment error boundary with a Try-again reset), and `loading.tsx` (a skeleton streamed while a route's data resolves). All match the existing Tailwind/slate design system, so a scaffolded app degrades gracefully out of the box instead of showing Next's bare fallback screens.
