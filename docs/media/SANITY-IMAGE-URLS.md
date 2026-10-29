<!-- doc-tier: agent | canonical-for: media-sanity-urls | budget: 1100tok -->
# Sanity image and file URLs

Barkpark answers the URL shapes of Sanity's image and file CDN from its own media files. A site that moves from Sanity keeps `@sanity/image-url` and changes its `baseUrl`. Images use the on-demand transforms in [IMAGE-TRANSFORMS.md](IMAGE-TRANSFORMS.md). Code: `Barkpark.Media.SanityAsset`, `BarkparkWeb.MediaController.serve_sanity_image/2` and `serve_sanity_file/2`.

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

A TanStack Studio pick stores `asset._ref: asset-<uuid>`, which the builder rejects. Pass the dereferenced asset, `image{..., asset->}`, whose `_id` is the Sanity id (full-read token: [groq-query.md](../contracts/groq-query.md)).

3. Browsers load the images without a token, so run `bp share publish-media <workspace>/<project>/<dataset>` once. Without it every anonymous request answers 403: [PUBLIC-MEDIA.md](PUBLIC-MEDIA.md).

## URLs

```
GET /w/:ws/p/:proj/images/<projectId>/<dataset>/<sha1>-<w>x<h>.<ext>[/<vanity>]?<transform params>
GET /w/:ws/p/:proj/files/<projectId>/<dataset>/<sha1>.<ext>[/<vanity>]
```

- The file is found by `sourceId` equal to the Sanity asset id (`image-<sha1>-<w>x<h>-<ext>`, `file-<sha1>-<ext>`) in that dataset, and otherwise by the sha1 of its stored bytes.
- `projectId` is ignored. The workspace and project in the prefix name the tenant.
- Access, share rules, `ETag` and `Cache-Control` are those of `/w/:ws/p/:proj/media/files/<path>`.
- Images take the transform parameters `@sanity/image-url` sends: `w`, `h`, `rect`, `fit`, `crop`, `fp-x`, `fp-y`, `fm`, `auto`, `q`, and `dpr`, `blur`, `bg`, `pad`, `flip`, `or`, `invert`, `sat` ([IMAGE-TRANSFORMS.md](IMAGE-TRANSFORMS.md)). When the stored original is smaller than `<w>x<h>`, `rect` is scaled to it. An SVG answers `auto=format` and size or crop parameters with the stored SVG, as Sanity does. An explicit `fm` on an SVG answers 400 `not_transformable`. SVGs are served `image/svg+xml`, `nosniff`, CSP `script-src 'none'` and `sandbox`: no script runs.
- `dl` downloads under the file's name, `dl=<name>` under that name.
- An unknown asset, another dataset or a malformed name answers 404.

## Recording the Sanity id

- `bp import <sanity export.tar.gz>` sends each asset's id.
- An importer sends a `sourceId` multipart field with `POST /w/:ws/p/:proj/v1/media/:dataset/upload`. If a file in that dataset carries the id, the upload answers 200 `existing: true` with it and stores nothing: re-runs are safe.
- Files imported without it: `PATCH /w/:ws/p/:proj/v1/media/:dataset/:id` with `{"sourceId": "image-..."}`. `null` clears it.
- A `sourceId` is 1–200 letters, digits, `.`, `_`, `:` and `-`, unique per dataset; malformed or taken: 422. Assets carry `sourceId`.

## Asset documents for Studio uploads

A LiveView Studio save of an image whose `asset._ref` is an `image-…` id with no document creates a published `sanityImageAsset` with that id when the workspace has that schema in the dataset, the editor may write, and a file in that workspace and dataset maps to the id. It never changes a document; else GROQ `->` answers a virtual `sanity.imageAsset`. Code: `Barkpark.Media.SanityImageAssetDoc`.

## Why a stored id

Sanity's sha1 hashes the bytes uploaded to Sanity. On one production import (155 files, 1,136 images, 2026-10-13), every file kept those bytes. Only 72 images kept Sanity's byte size, and 3 of 30 sampled kept its sha1, as the importer fetched them from Sanity's re-encoding CDN. 17 came back capped at 8192 px. The sha1 lookup needs the stored hash: run `bin/barkpark eval 'Barkpark.Release.backfill_media_sha1()'` for rows uploaded before the column existed.
