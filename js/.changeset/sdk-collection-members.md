---
'@barkpark/core': minor
---

Added media-collection membership writes: `client.addCollectionMember(id, assetId)` and `client.removeCollectionMember(id, assetId)` — organize assets into collections (folders), the write side of the read-only collection API shipped earlier. Both return the affected `MediaAsset`. (Collection share/revoke are a separate follow-up.)
