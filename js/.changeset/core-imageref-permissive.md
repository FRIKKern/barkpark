---
'@barkpark/core': patch
---

`ImageRef` (the `imageUrl` input type) no longer carries an index signature, so it accepts any structurally-compatible asset — including the react `ImageAsset` interfaces — without a cast.
