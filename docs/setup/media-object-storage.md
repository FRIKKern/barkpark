# Media on object storage (S3 / R2 / MinIO / B2)

By default Barkpark stores media blobs on local disk under the media root
(`BARKPARK_MEDIA_DIR`, default `api/uploads`). Setting
`BARKPARK_MEDIA_STORAGE=s3` moves **originals** into any S3-compatible bucket
and demotes local disk to a regenerable write-through cache.

## What changes, what doesn't

| Concern | `:local` (default) | `:s3` |
| --- | --- | --- |
| Original bytes | disk under media root | the bucket (source of truth) |
| Renditions (`thumb`/`preview`/`hero`/`og`) | disk, `_renditions/` | unchanged — disk, regenerable cache |
| Serving originals | `send_file` from disk | `302` → presigned URL (or CDN URL) |
| Serving renditions | `send_file` from disk | unchanged |
| Upload / blob-push / delete API | — | unchanged shapes; storage faults still answer typed `503`s |
| Losing the disk | loses blobs | loses only cache — re-fetched / regenerated on demand |

Auth, tenancy scoping, signed embed URLs, and the serve edge's stored-XSS
defenses are backend-independent: on the redirect path the collapsed
content-type and `attachment` disposition are baked into the **signed** query
(`response-content-type` / `response-content-disposition`), so the bucket
echoes exactly the headers the local path would set.

## Configuration

```bash
BARKPARK_MEDIA_STORAGE=s3
BARKPARK_S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
BARKPARK_S3_BUCKET=barkpark-media
BARKPARK_S3_ACCESS_KEY_ID=…
BARKPARK_S3_SECRET_ACCESS_KEY=…

# optional
BARKPARK_S3_REGION=auto            # default "auto" (R2); AWS wants a real region
BARKPARK_S3_KEY_PREFIX=            # namespace inside the bucket
BARKPARK_S3_PRESIGN_TTL=3600       # presigned-URL lifetime, seconds
BARKPARK_S3_PUBLIC_BASE_URL=       # see "Public delivery" below
```

Boot fails loudly if the backend is selected with incomplete credentials — a
half-configured bucket must not silently fall back to local and split the
blob set across two stores.

Provider notes:

- **Cloudflare R2** — endpoint `https://<account-id>.r2.cloudflarestorage.com`,
  region `auto`. Mint a scoped R2 API token (Object Read & Write on one bucket).
- **AWS S3** — endpoint `https://s3.<region>.amazonaws.com`, real region.
- **MinIO / localhost** — `http://localhost:9000`; non-default ports are
  handled in the signature.

## Public delivery (optional)

`BARKPARK_S3_PUBLIC_BASE_URL` short-circuits presigning with a plain
`{base}/{key}` redirect — for a public bucket behind a CDN (e.g. R2 with a
custom domain). It is only used for serves the caller marks safe; dangerous
mime types and access-gated assets always take the presigned path where the
signed response-header overrides hold.

## Migrating an existing instance

Object keys are the existing relative paths (`YYYY/MM/slug-rand.ext`), so
migration is a plain copy — no DB changes:

```bash
rclone copy /opt/barkpark/uploads r2:barkpark-media \
  --exclude "_renditions/**"
```

Then set the `BARKPARK_S3_*` env and restart. The disk copies simply become
the warm cache. Rolling back is the same copy in reverse (or nothing, if the
cache is still intact).

## Limits

- Uploads are buffered in memory for the bucket PUT (bounded by the existing
  100 MB request cap). Streaming multipart/aws-chunked upload is a follow-up.
- The redirect serve is a blind 302; a row whose object was deleted
  bucket-side answers the bucket's 404 rather than the app's enveloped one.
- The local cache is append-only today — no eviction. Disk usage ≈ hot set of
  originals + all renditions, same order as the pre-S3 footprint.
