<!-- doc-tier: agent | canonical-for: media-sanity-urls | budget: 1100tok -->
# Sanity image and file URLs

Barkpark answers the URL shapes of Sanity's image and file CDN from its own media files. A site that moves from Sanity keeps `@sanity/image-url` and changes its `baseUrl`. Images are served through the on-demand transforms in [IMAGE-TRANSFORMS.md](IMAGE-TRANSFORMS.md). Code: `Barkpark.Media.SanityAsset`, `BarkparkWeb.MediaController.serve_sanity_image/2` and `serve_sanity_file/2`.

## Moving images from Sanity

1. Import the assets so each Barkpark file records its Sanity asset id (below).
2. Point the builder at the workspace and project:

```ts
import {createImageUrlBuilder} from '@sanity/image-url'

const builder = createImageUrlBuilder({
  projectId: 'abc123de', // any value; Barkpark ignores it
  dataset: 'production', // the Barkpark dataset
  baseUrl: 'https://<host>/w/<workspace>/p/<project>',
})

builder.image(post.mainImage).width(800).height(600).auto('format').url()
```

`@sanity/image-url` 1.x takes the same options through its default export. Crop and hotspot need no change: the builder sends them as `rect`. For file URLs, replace `https://cdn.sanity.io` with the same prefix.

3. Browsers load the images without a token, so run `bp share publish-media <workspace>/<project>/<dataset>` once. Without it every anonymous request answers 403: [PUBLIC-MEDIA.md](PUBLIC-MEDIA.md).

## URLs

```
GET /w/:ws/p/:proj/images/<projectId>/<dataset>/<sha1>-<w>x<h>.<ext>[/<vanity>]?<transform params>
GET /w/:ws/p/:proj/files/<projectId>/<dataset>/<sha1>.<ext>[/<vanity>]
```

- The file is found by `sourceId` equal to the Sanity asset id (`image-<sha1>-<w>x<h>-<ext>`, `file-<sha1>-<ext>`) in that dataset, and otherwise by the sha1 of its stored bytes.
- `projectId` is ignored. The workspace and project in the prefix name the tenant.
- Access, share rules, `ETag` and `Cache-Control` are those of `/w/:ws/p/:proj/media/files/<path>`.
- Images take the transform parameters `@sanity/image-url` sends: `w`, `h`, `rect`, `fit`, `crop`, `fp-x`, `fp-y`, `fm`, `auto`, `q`. When the stored original is smaller than `<w>x<h>`, `rect` is scaled to it. `dpr`, `blur`, `flip`, `bg` and the rest answer 400 `unsupported_transform_param`. An SVG answers `auto=format` and size or crop parameters with the stored SVG, as Sanity does. An explicit `fm` on an SVG answers 400 `not_transformable`. Every SVG is served `image/svg+xml` with `nosniff` and a CSP holding `script-src 'none'` and `sandbox`, so its script never runs.
- Files ignore query parameters, Sanity's `dl` included.
- An unknown asset, another dataset or a malformed name answers 404.

## Recording the Sanity id

- `bp import <sanity export.tar.gz>` sends each asset's id.
- An importer sends a `sourceId` multipart field with `POST /w/:ws/p/:proj/v1/media/:dataset/upload`. If a file in that dataset already carries the id, the upload answers 200 `existing: true` with that asset and stores nothing, so a re-run is safe.
- Files imported without it: `PATCH /w/:ws/p/:proj/v1/media/:dataset/:id` with `{"sourceId": "image-..."}`. `null` clears it.
- A `sourceId` is 1 to 200 characters of letters, digits, `.`, `_`, `:` and `-`, unique per dataset. A malformed or taken id answers 422. Assets carry `sourceId`.

## Why a stored id

Sanity's sha1 is the hash of the bytes uploaded to Sanity. On one production import of 155 files and 1,136 images, read on 2026-10-13, every file kept those bytes. Only 72 images kept Sanity's byte size, and 3 of 30 sampled kept its sha1, because the importer downloaded them from Sanity's CDN, which re-encodes. 17 came back capped at 8192 px. The sha1 lookup also needs the stored hash: run `bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'` for rows uploaded before the column existed.
