---
'@barkpark/core': patch
---

core: validate the asset/collection id in media write ops. `updateAsset`, `deleteAsset`, `checkoutAsset`, `undoCheckoutAsset`, `getAssetRelations`, `getCollectionAssets`, `addCollectionMember`, `removeCollectionMember`, `shareCollection`, and `revokeCollectionShare` now throw a `BarkparkValidationError` up front when the id (or, for the collection-member ops, the `assetId`) is an empty string, matching the guard every other SDK write path already enforces. Previously an empty id fed straight into `encodeURIComponent`, collapsing the request path (e.g. `//checkout`) and surfacing as an opaque server 404/405 instead of a self-explaining client-side error. No network request is made when the guard fires.
