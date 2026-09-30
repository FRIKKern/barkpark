---
'create-barkpark-app': patch
---

The blog-starter's `/api/preview` and `/api/exit-preview` now redirect with a relative `Location`. Under a self-hosted `next start`, `req.url` carries the server's bind host, so the absolute redirect sent every editor behind a real host or proxy to `localhost:<port>`.
