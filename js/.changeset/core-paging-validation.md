---
'@barkpark/core': patch
---

The ad-hoc read paths now validate paging eagerly. `search()` and every media list/search builder (`listAssets`, `searchAssets`, `getAssetSearchSuggestions`, `listCollections`, `getCollectionAssets`) throw a self-explaining `BarkparkValidationError` on an invalid `limit`/`offset` (e.g. `offset:-5`, `limit:NaN`, `limit:0`) instead of shipping a garbage query string that the server answers with an opaque 400/500. A new exported `assertPaging(limit?, offset?)` helper backs this — same rules as the `docs()` builder guards but without the 1..1000 upper cap (search/media accept larger server-side page sizes).
