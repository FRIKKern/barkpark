---
'@barkpark/core': patch
---

`verifyWebhookSignature` now returns `false` when `secret` is empty or missing. Before, it threw.

The usual call is `secret: process.env.BARKPARK_WEBHOOK_SECRET!`. With that variable unset, the secret reached Web Crypto as a zero-length HMAC key. Node rejects such a key with `DataError: Zero-length key is not supported`, so the function threw, despite its documented "never throws" contract. A runtime that accepted a zero-length key would instead have verified a signature anyone can compute. The function now refuses by its own guard, so the result is the same on every runtime.
