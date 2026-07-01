---
'@barkpark/core': patch
---

exportDataset() now wraps a malformed NDJSON line in a typed BarkparkAPIError instead of leaking a raw SyntaxError, so a truncated or proxy-corrupted stream stays isBarkparkError()-catchable.
