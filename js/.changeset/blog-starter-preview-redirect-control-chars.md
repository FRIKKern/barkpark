---
'create-barkpark-app': patch
---

blog-starter: `/api/preview` and `/api/exit-preview` no longer redirect a visitor off-site through `?path=`.

Both routes accepted any `path` that started with `/` and not with `//` or `/\`. A browser strips ASCII tab, LF and CR from a URL before resolving it, so `?path=/%09/evil.example` passed and the browser followed it to `//evil.example`. `/api/exit-preview` needs no secret, so any link to a scaffolded blog could bounce its visitors to another site.

The routes now accept only a path with no control characters and no backslash that resolves on the site's own origin; anything else redirects to `/`. Regenerate or copy the two route files into projects scaffolded from an earlier version.
