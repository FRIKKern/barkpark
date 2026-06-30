---
'@barkpark/core': minor
---

The SDK now exposes media collections (read side): `client.listCollections()`, `client.getCollection(id)` (null on 404), and `client.getCollectionAssets(id, { limit, offset })`. The server has organized assets into collections (folders / smart-folders) all along — `GET /v1/media/:dataset/collections[/:id[/assets]]` — but the SDK only exposed flat asset CRUD, so a media-library / folder UI was impossible from `client`. New types: `MediaCollection`, `MediaCollectionPage`, `MediaCollectionAssets`, `CollectionAssetsOptions`.
