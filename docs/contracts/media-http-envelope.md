<!-- doc-tier: agent | canonical-for: media-http-envelope | budget: 650tok -->
# `/v1/media/*` response envelope

What a media asset record and a media list `result` actually carry. Split out of [api-v1.md](../api-v1.md) §8d/§8e; the generic envelope, auth markers and error codes stay there (§3, §2, §9). Search/media feature overview: [`../cards/search-media.md`](../cards/search-media.md).

## Media asset record — `absoluteUrl`

Asset urls (`url`/`originalUrl`/`previewUrl`/`thumbnailUrl`/`renditions.*`/`cdnUrls.*`) are RELATIVE paths and stay so. The upload `201` and `GET /v1/media/:dataset/:id` also carry **`absoluteUrl`** — same binary, host from `:media_cdn, :base_url` else the API's origin (`PHX_SCHEME`/`PHX_HOST`), `/w/:ws/p/:proj` prefix applied.

## List envelope

Every list `result` carries `total` (grand total, stable across pages), `hasMore` (exact, always present — **never infer truncation from `rows == limit`**: an exactly-full last page has it too), `limit`, `offset`, and `nextOffset` = `offset + rows`, present **only** when `hasMore`. `search` uses `nextCursor` instead (always present, `null` unless `hasMore`), no `nextOffset`.

**`count` means opposite things on the two routes that carry it — it is legacy, prefer `total`.** Neither was re-pointed: that would silently break whichever consumer reads it correctly today.

| Route | Rows key | `count` | Also |
|---|---|---|---|
| `GET /v1/media/:ds` | `assets` | **grand total** (≡ `total`) | — |
| `GET /v1/media/:ds/collections` | `collections` | **page rows** | — |
| `GET /v1/media/:ds/collections/:id/assets` | `hits` | *absent* | `collectionId`, `facets` |
| `GET /v1/media/:ds/search` | `hits` | *absent* | `facets`, `nextCursor` |
| `GET /v1/media/:ds/share/:token` | `hits` | *absent* | `collection` |
