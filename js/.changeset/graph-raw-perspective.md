---
"@barkpark/core": patch
---

getGraph now throws BarkparkValidationError on a client-wide perspective:'raw' with no override instead of silently downgrading to published.
