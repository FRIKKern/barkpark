---
'@barkpark/core': patch
---

`imageUrl` now wraps the asset id in `encodeURIComponent` when building both the rendition path (`/media/renditions/<id>/<preset>`) and the `/images/<id>` fallback, matching the other read/write path builders. Prevents a malformed or truncated `<img src>` when an asset id contains a space or a URL-reserved character (`/`, `#`, `?`, …). No-op for slug-valid ids.
