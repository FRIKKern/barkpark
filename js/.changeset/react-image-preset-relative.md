---
'@barkpark/react': patch
---

`<BarkparkImage preset="…">` no longer silently discards the preset when `baseUrl` is omitted. It now delegates to core `imageUrl` exactly: with a `baseUrl` you get an absolute rendition URL, and without one you get the relative `/media/renditions/<id>/<preset>` path — which is valid for the common same-origin case (e.g. a Next.js app served from the same host as the API). Previously a preset without `baseUrl` downgraded to the full-size original, diverging from `imageUrl(asset, { preset })`. Bare-string assets (no id) still fall back to the string url unchanged.
