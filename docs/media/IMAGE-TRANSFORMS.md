<!-- doc-tier: agent | canonical-for: media-image-transforms | budget: 1300tok -->
# Image transforms

Barkpark stores an image once and makes each size, crop and format on first request, cached on disk, like Sanity.

## Upload

`POST /v1/media/:dataset/upload` stores the original and writes the `mediaAsset` document once: `fileInfo.width`, `height`, a 24 px `lqip`, `bp_processing_status` (`"failed"` when libvips cannot decode it) and Sanity's `metadata` (`dimensions`, `lqip`, `blurHash`, `hasAlpha`, `isOpaque`, `palette`; `exif`, `location` with `meta=exif,location`). No renditions. Code: `Barkpark.Plugins.Media.after_media_upload/1`, `Barkpark.Media.Processing`.

## URL

```
GET /media/files/<path>?w=800&h=450&fit=crop&fp-x=0.3&fp-y=0.4&auto=format&q=70
```

`<path>` is the asset's `path` (in `url`, `originalUrl`), also under `/w/:ws/p/:proj`. No parameters: the original bytes. Outputs keep an ICC profile, no EXIF (so no GPS); JPEGs get optimised Huffman tables.

Sanity CDN URLs from `@sanity/image-url` take the same parameters: [SANITY-IMAGE-URLS.md](SANITY-IMAGE-URLS.md).

Anonymous reads need the scope's `:media` share: [PUBLIC-MEDIA.md](PUBLIC-MEDIA.md).

| Param | Values | Meaning |
|---|---|---|
| `w`, `h` | integer ≥ 1 | Output size; one side keeps the aspect. |
| `fit` | `clip` (default), `crop`, `fill`, `fillmax`, `max`, `min`, `scale` | How `w` x `h` is met; see below. |
| `crop` | `center`, `focalpoint`, `top`, `bottom`, `left`, `right` (comma list), or `entropy`, `attention` | Which part `fit=crop` and `fit=min` keep. |
| `rect` | `left,top,width,height` | Pixel area of the original to cut first. |
| `fp-x`, `fp-y` | 0 to 1 | Focal point, as fractions of the image after `rect`. Implies `crop=focalpoint`. |
| `fm` | `jpg` (`pjpg`), `png`, `webp`, `avif` | Output format. Default: the source format (`gif` gives `png`). |
| `auto` | `format` | Serve AVIF or WebP when `Accept` allows it; see AVIF. |
| `q` | 1 to 100 | Quality, default 75, rounded to a multiple of 5. |

Fit modes:

- `clip` fits inside the box, keeps the aspect, may scale up; `max` does not.
- `crop` scales to cover the box, then cuts it to `w` x `h`.
- `fill` is `clip`, padded to `w` x `h` with `bg` (white); `fillmax` does not scale up.
- `scale` stretches to `w` x `h`.
- `min` is `crop` without scaling up: a smaller source is cut to the box's aspect at its own size.

Also: `dpr` 1–5 multiplies `w`/`h`; `blur` 0–2000 (σ = blur/10 px); `bg` hex (RGB, ARGB, 6 or 8 digits; JPEG drops alpha); `pad` px a side, inside `w`/`h`; `flip` `h`/`v`/`hv`; `or` 0/90/180/270 turns the result; `invert`; `sat=-100` grayscale, else ignored; `sharp` ignored; `quality` is `q`.

## AVIF

AVIF uses libvips effort 1 of 0 to 9; `Transform.avif_quality/1` maps `q` (75 gives 55) so an AVIF is no larger than WebP at the same `q`. `auto=format` picks AVIF only when output megapixels times the node's measured AVIF ms per megapixel fits 1500 ms; else WebP, cached as usual. `fm=avif` always gets AVIF. Settings: `Barkpark.Media.Transform` moduledoc. Bench: `api/bench/image_transform_bench.exs`.

## Crop and hotspot

The asset's stored focal point, `mediaAsset.focalPoint` `{x, y}` as fractions, applies when a URL uses `fit=crop` or `fit=min` without `crop` or `fp-x`/`fp-y`.

A Sanity-shaped image value stores `crop` `{top, bottom, left, right}` and `hotspot` `{x, y, width, height}` as fractions of the original. With the original's `width` W and `height` H, a consumer builds the URL like this:

- `rect` = `round(left*W), round(top*H), round((1-left-right)*W), round((1-top-bottom)*H)`
- `fp-x` = `(hotspot.x - left) / (1 - left - right)`, `fp-y` = `(hotspot.y - top) / (1 - top - bottom)`

## Caching and limits

- The cache key is a SHA-256 of the normalised parameters, the chosen format, the watermark profile and the focal point. An AVIF key adds the encoder settings. Files live at `_renditions/<asset id>/t/<hash>.<fm>`, deleted with the asset.
- Concurrent first requests for one key render once.
- A public asset answers `Cache-Control: public, max-age=2592000`, a strong `ETag`, `304` on `If-None-Match`, and `Vary: Accept`. A non-public asset answers `no-store`.
- `w`, `h` cap at 4096; above 100 they round up to a multiple of 10. An asset keeps at most 100 cached transforms; past that a new one is 429 `transform_variant_limit`. Config: `Barkpark.Media.Transform` (`max_dimension`, `dimension_step`, `max_variants_per_asset`).
- Access is the original's check (`:original`). A watermark profile on the asset is applied to the transform.

Errors: 400 `invalid_transform_param` (`details.param`), 400 `not_transformable` (not png, jpeg, gif or webp; an SVG is served as is unless `fm` is set), 400 `transforms_unsupported` (the ImageMagick backend on Windows), 404, 403, 429 `transform_variant_limit`.

## Named presets

`/media/renditions/<id>/<preset>` (`thumb`, `preview`, `hero`, `og`, `lqip`) runs a fixed plan through one pipeline (`ImageBackend.Vix.render/4`), cached as `_renditions/<id>/<preset>.<ext>`.

Code: `Barkpark.Media.Transform` (parameters, cache key, geometry), `Barkpark.Media.Renditions.transform/3` (cache, lock), `BarkparkWeb.MediaController.serve/2`.
