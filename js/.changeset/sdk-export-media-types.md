---
'@barkpark/core': patch
---

**Fixed:** re-export `MediaAssetPage`, `AssetOptions`, and `ListAssetsOptions` from the package root. They were used in public client method signatures (`listAssets(): Promise<MediaAssetPage>`, `getAsset(opts?: AssetOptions)`, etc.) but never exported, so a TypeScript consumer could call the methods yet couldn't *name* their option/result types (e.g. to type a wrapper function's params or a variable holding the result). No runtime change — types only.
