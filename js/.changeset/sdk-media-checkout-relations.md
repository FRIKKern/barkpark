---
'@barkpark/core': minor
---

**Added:** three media-asset operations the API had but the SDK didn't expose — `client.checkoutAsset(id)` / `client.undoCheckoutAsset(id)` (the advisory editorial lock, `POST .../:id/checkout` and `.../undo-checkout`; checkout throws `BarkparkConflictError` when another editor holds it) and `client.getAssetRelations(id)` (`GET .../:id/relations` → `{ outbound, inbound }` — where-used / impact analysis before a delete). Completes the media-asset SDK surface alongside upload/get/update/delete. New `AssetRelations` + `AssetRelationEdge` types.
