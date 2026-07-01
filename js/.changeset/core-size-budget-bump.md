---
'@barkpark/core': patch
---

Raise the bundle-size budget from 14 KB to 15 KB. The CJS bundle reached 14.07 KB — a 74-byte (0.5%) overage from legitimate shipped features (webhook management, media asset APIs, schema write ops, collections, `isBarkparkError`), well under the 2% regression threshold; the 14 KB limit simply had zero headroom. No runtime change.
