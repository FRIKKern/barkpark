---
'@barkpark/core': minor
---

Media management — `client.listAssets(opts)`, `client.getAsset(id)`, and `client.deleteAsset(id)`. The SDK could upload assets but not browse, inspect, or delete them, though the server (and `bp media ls`) already supported it. `listAssets` paginates (`limit`/`offset`, `count` is the total); `getAsset` returns `null` on 404; `deleteAsset` returns `{ deleted: id }`. All accept an `AbortSignal`. Completes the media CRUD alongside `uploadAsset`.
