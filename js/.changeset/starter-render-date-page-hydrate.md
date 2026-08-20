---
'create-barkpark-app': patch
---

Harden the starter render paths. Add a per-template `lib/format-date.ts` whose `formatDate(iso?)` returns `null` for absent or unparseable dates, and route the four date render sites (blog `page.tsx`, blog `posts/[slug]/page.tsx`, blog `draft-preview.tsx`, website `posts/[slug]/page.tsx`) through it — a malformed-but-truthy `publishedAt` no longer renders the literal `Invalid Date`. Floor the blog home page number so a fractional `?page=2.5` can't send a fractional offset. Attach a `.catch(() => {})` to the blog PortableDoc surface's `hydratePortableDoc` call so a hydration reject is no longer an unhandled rejection.
