---
"@barkpark/react": patch
---

BarkparkImage: URL-encode the asset id in the `/images/<id>` fallback src, matching `@barkpark/core`'s `imageUrl` and Reference's `buildDocPath`. An asset whose `_ref`/`_id` contains a space, `#`, `?`, `/`, or non-ASCII (all legal Barkpark ids) now yields a valid `<img src>` instead of a broken/ambiguous one.
