---
'create-barkpark-app': patch
---

Fix by-id 404 handling in both starter templates: `getDocById` (blog-starter) and `getDoc` (website-starter) called `barkparkFetch` with no catch, so a by-id miss threw `BarkparkNotFoundError` — which carries no `NEXT_NOT_FOUND` digest — and App Router rendered the error boundary (500) instead of `not-found.tsx` (404), making every downstream `if (!doc) notFound()` guard dead code. Both helpers now swallow `BarkparkNotFoundError` to `null` (symmetric with `getDocBySlug` and the SDK's `client.doc` 404→null convention) and rethrow all other errors. Fixes `authors/[id]`, a valid post 500ing on a dangling author/tag `_ref`, and the website home/about/pricing pages 500ing before their content is seeded.
