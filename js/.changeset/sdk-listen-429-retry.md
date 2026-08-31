---
'@barkpark/core': patch
---

`listen()` now survives a 429 during (re)connect instead of dying without backoff. `assertStreamResponse` throws a rate limit as a plain `BarkparkAPIError` with `status: 429`, and the reconnect classifier only treated `status >= 500` as retryable — so the one status a reconnect storm is most likely to produce (every client hitting a shared rate-limit bucket at once after a restart) killed the whole subscription on the first attempt, with zero backoff. 429 now folds into the same retryable class as 5xx and reuses the existing jittered exponential backoff and `maxReconnects` budget; 401/403 are unaffected and still throw immediately with no reconnect.
