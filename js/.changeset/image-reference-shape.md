---
'@barkpark/core': patch
'@barkpark/react': patch
'@barkpark/codegen': patch
---

`imageUrl` and `<BarkparkImage>` now read an image in the reference shape, `{asset: {_ref: "image-<sha1>-<w>x<h>-<ext>"}}`, which Barkpark writes when `BARKPARK_CANONICAL_SHAPE_WRITES` is on. The legacy `{url, assetId}` value and every other shape resolve exactly as before.

- The URL is the dataset's image route, `<baseUrl><pathPrefix>/images/barkpark/<dataset>/<sha1>-<w>x<h>.<ext>`, the same one the server builds. A known `preset` adds its bounds as `w`/`h`/`fit`. An `asset` expanded with a `url` uses that url.
- `imageUrl` takes a new `dataset` option, and `<BarkparkImage>` a new `dataset` prop. Without one, a reference-shape image has no URL. A ref whose `_dataset` names another dataset has no URL.
- `client.imageUrl` always uses the client's own dataset and ignores a `dataset` option. A flat client (no `workspace`/`project`) gives a reference-shape image no URL, because the route exists only under `/w/<ws>/p/<proj>`.
- The new `ImageReferenceValue` type in `@barkpark/react` describes this shape. Codegen's `BarkparkImage` type gains `assetId` and `asset`.
