---
'create-barkpark-app': patch
---

blog-starter: generate per-page SEO metadata. The post, author, and tag pages now export `generateMetadata`, so each renders its own `<title>`, `<meta name="description">`, and OpenGraph tags (post pages as `type: 'article'` with `publishedTime`) instead of inheriting the site-wide static title/description from the layout. Descriptions come from the post excerpt / author bio / tag description, with sensible fallbacks. Metadata always reflects the published document, and reuses the request-memoized fetch so it doesn't double-fetch.
