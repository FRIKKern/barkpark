---
'create-barkpark-app': patch
---

website-starter: generate per-page SEO metadata. The post, about, and pricing pages now export `generateMetadata`, so each renders its own `<title>`, `<meta name="description">`, and OpenGraph tags (post pages as `type: 'article'` with `publishedTime`) instead of inheriting the site-wide static title from the layout. Descriptions come from the post excerpt / page subtitle. Fetches reuse Next.js request memoization, so no extra round-trip. (The contact page is a client component and keeps the layout default.)
