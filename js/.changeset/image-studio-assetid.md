---
'@barkpark/core': patch
'@barkpark/react': patch
---

`imageUrl` and `<BarkparkImage>` now read the image value the Studio media picker stores, `{url, assetId, alt, width, height, lqip}`.

- A `preset` now resolves `/media/renditions/<assetId>/<preset>`. Before, every Studio-authored image fell through to the full-size original.
- `BarkparkImage` now forwards the stored `width`/`height`, and passes `lqip` as `blurDataURL` to a custom component.
- The new `ImageFieldValue` type describes this shape.
