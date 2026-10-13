<!-- doc-tier: agent | canonical-for: media-image-transforms | budget: 1300tok -->
# Image transforms

Barkpark stores an uploaded image once and makes every size, crop and format on the first request for it. The result is cached on disk, so later requests read a file. Sanity's image pipeline and `next/image` work the same way.

## Upload

`POST /v1/media/:dataset/upload` writes the original, hashes it for dedupe, reads width and height from the header, and renders a 24 px LQIP in memory. It then creates the `mediaAsset` document in one write, with `fileInfo.width`, `fileInfo.height`, `fileInfo.lqip`, `bp_processing_status` and any inline metadata. It builds no renditions. A raster image libvips cannot decode is stored with `bp_processing_status: "failed"`. Code: `Barkpark.Plugins.Media.after_media_upload/1`, `Barkpark.Media.Processing`.

## URL

```
GET /media/files/<path>?w=800&h=450&fit=crop&fp-x=0.3&fp-y=0.4&auto=format&q=70
```

`<path>` is the asset's `path`; `url` and `originalUrl` already carry it. The scoped form `/w/:ws/p/:proj/media/files/<path>` takes the same parameters. Without transform parameters the URL serves the original bytes, as before.

Sanity CDN URLs from `@sanity/image-url` take the same parameters: [SANITY-IMAGE-URLS.md](SANITY-IMAGE-URLS.md).

Anonymous reads, as a website's `<img>` makes, need the scope's `:media` share: [PUBLIC-MEDIA.md](PUBLIC-MEDIA.md).

| Param | Values | Meaning |
|---|---|---|
| `w`, `h` | integer ≥ 1 | Output size in pixels. One side alone keeps the aspect ratio. |
| `fit` | `clip` (default), `crop`, `fill`, `max`, `min` | How `w` x `h` is met; see below. |
| `crop` | `center`, `focalpoint`, `top`, `bottom`, `left`, `right` (comma list), or `entropy`, `attention` | Which part `fit=crop` and `fit=min` keep. |
| `rect` | `left,top,width,height` | Pixel area of the original to cut first. |
| `fp-x`, `fp-y` | 0 to 1 | Focal point, as fractions of the image after `rect`. Implies `crop=focalpoint`. |
| `fm` | `jpg`, `png`, `webp`, `avif` | Output format. Default: the source format (`gif` gives `png`). |
| `auto` | `format` | Serve AVIF or WebP when the `Accept` header allows it. |
| `q` | 1 to 100 | Quality, default 75, rounded to a multiple of 5. |

Fit modes:

- `clip` scales to fit inside the box and keeps the aspect ratio. It may scale up.
- `max` is `clip` without scaling up.
- `crop` scales to cover the box, then cuts it to exactly `w` x `h`.
- `fill` is `clip` and then pads to exactly `w` x `h` with white.
- `min` is `crop` without scaling up. A source smaller than the box is cut to the box's aspect ratio at its own size.

`dpr`, `blur`, `sharp`, `flip`, `or`, `quality`, `bg`, `invert`, `sat` and `pad` are refused with 400 `unsupported_transform_param`, so a request is never answered with bytes it did not ask for.

## Crop and hotspot

The asset's stored focal point, `mediaAsset.focalPoint` `{x, y}` as fractions, applies when a URL uses `fit=crop` or `fit=min` without `crop` or `fp-x`/`fp-y`.

A Sanity-shaped image value stores `crop` `{top, bottom, left, right}` and `hotspot` `{x, y, width, height}` as fractions of the original. With the original's `width` W and `height` H, a consumer builds the URL like this:

- `rect` = `round(left*W), round(top*H), round((1-left-right)*W), round((1-top-bottom)*H)`
- `fp-x` = `(hotspot.x - left) / (1 - left - right)`, `fp-y` = `(hotspot.y - top) / (1 - top - bottom)`

## Caching and limits

- The cache key is a SHA-256 of the normalised parameters, the chosen format, the watermark profile and the focal point. The file lives at `_renditions/<asset id>/t/<hash>.<fm>` and is deleted with the asset.
- Concurrent first requests for one key render once; the others wait for that file.
- A public asset answers `Cache-Control: public, max-age=2592000`, a strong `ETag`, `304` on `If-None-Match`, and `Vary: Accept`. A non-public asset answers `no-store`.
- `w` and `h` are capped at 4096 and values above 100 round up to a multiple of 10. One asset keeps at most 100 cached transforms; a new one past that answers 429 `transform_variant_limit`, while cached ones still serve. Set them in `config :barkpark, Barkpark.Media.Transform` (`max_dimension`, `dimension_step`, `max_variants_per_asset`).
- Access is the same check as the original (`:original`). A watermark profile on the asset is applied to the transform.

Errors: 400 `invalid_transform_param` (bad value, `details.param`), 400 `not_transformable` (not png, jpeg, gif or webp), 400 `transforms_unsupported` (the ImageMagick backend on Windows), 404, 403, 429 `transform_variant_limit`.

## Named presets

`/media/renditions/<id>/<preset>` (`thumb`, `preview`, `hero`, `og`, `lqip`) keeps working. Each preset is a fixed transform plan built on its first request through the same libvips pipeline (`Barkpark.Media.ImageBackend.Vix.render/4`) and cached as `_renditions/<id>/<preset>.<ext>`.

Code: `Barkpark.Media.Transform` (parameters, cache key, geometry), `Barkpark.Media.Renditions.transform/3` (cache, lock), `BarkparkWeb.MediaController.serve/2`.
