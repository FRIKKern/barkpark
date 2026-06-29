---
'@barkpark/core': minor
---

New `imageUrl` helper — the preset-based equivalent of Sanity's `urlFor`. Turns a stored image field (a `{_ref}` reference, an expanded `{_id, url}` asset, or a bare URL string) into the right URL: `imageUrl(asset, { preset: 'hero' })` → the rendition route `/media/renditions/<id>/<preset>` (presets `thumb`/`preview`/`hero`/`og`), or the original when no preset is given. Available standalone (`import { imageUrl }`) and as `client.imageUrl(asset, opts)`, which defaults `baseUrl` to the configured `projectUrl`.
