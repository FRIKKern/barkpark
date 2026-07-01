---
'@barkpark/core': minor
---

**Added:** `client.updateAsset(id, metadata)` — patch a media asset's metadata (alt text, caption, tags, focal point, …) via `PATCH /v1/media/:dataset/:id`. A partial update: only the passed keys change. The API supported this all along, but the SDK exposed only `uploadAsset`/`deleteAsset`, so editing asset metadata (a core media-library operation) required a raw fetch. New `UpdateAssetInput` type; the response is the updated `MediaAsset`.
