---
'create-barkpark-app': patch
'@barkpark/nextjs': patch
---

Fix scaffold stale-content bug + add `barkparkMetadata`.

**create-barkpark-app (stale-content fix):** the `blog-starter` and
`website-starter` `lib/barkpark.ts` helpers hand-rolled `fetch` and hard-coded
LEGACY flat cache tags (`bp:ds:<ds>:type:<type>` / `:doc:<id>`). For a
workspace+project-scoped config the webhook `revalidateBarkpark` emits SCOPED
tags (`bp:ws:<ws>:p:<project>:ds:<ds>:…`), so read-tags never matched write-tags
and `revalidateTag` silently no-oped — permanent stale content. The helpers now
delegate to the SDK's `barkparkFetch`, so cache tags come from the shared
`formatTagPrefix` and read-tags match the webhook's write-tags for BOTH flat and
scoped configs. Also fixed for free: drafts use the SDK's canonical
`cache: 'no-store'` path (not `revalidate: 0`), and `countDocs` returns the
envelope's true `result.count` instead of one page's length.

**@barkpark/nextjs (new helper):** added `barkparkMetadata(doc, { title?,
description? })`, a pure helper that builds a Next.js `Metadata` object
(`{ title, description, openGraph }`) from a Barkpark document — deriving an OG
`article` (with `publishedTime`) from `publishedAt`, else `website`, and
degrading gracefully on a missing/`null` doc. Replaces the hand-rolled metadata
boilerplate across the starter templates' `generateMetadata`.
