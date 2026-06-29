---
'@barkpark/react': minor
---

`<BarkparkImage>` gains a `preset` prop (`thumb`/`preview`/`hero`/`og`) — render a server rendition (`/media/renditions/<id>/<preset>`) instead of the full-size original, for faster image loads. Also re-exports `imageUrl` (+ `RenditionPreset`/`ImageRef`/`ImageUrlOptions`) from `@barkpark/core`, so react consumers can build image URLs without a separate core import.
