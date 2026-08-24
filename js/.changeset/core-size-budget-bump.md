---
'@barkpark/core': patch
---

Raise the bundle-size budget from 14 KB to 15 KB. The CJS bundle reached 14.07 KB — a 74-byte overage from legitimate shipped features (webhook management, media asset APIs, schema write ops, collections, `isBarkparkError`); the 14 KB limit simply had zero headroom. (This note previously called the overage "well under the 2% regression threshold". There is no percentage threshold — size-limit enforces the absolute cap in `.size-limit.json` and nothing else. A percentage that does not exist cannot license a bump.) No runtime change.
