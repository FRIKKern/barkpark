---
---

Bump `@barkpark/core`'s bundle-size budget from 14 KB to 15 KB. The CJS bundle grew to 14.07 KB — a 74-byte (0.5%) overage from legitimate shipped features (webhook management, media asset APIs, schema write ops, collections, `isBarkparkError`), well under the 2% regression threshold. The 14 KB limit had zero headroom; 15 KB restores a small buffer. Config-only — no published behavior change, so no version bump.
