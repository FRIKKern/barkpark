---
'@barkpark/core': patch
---

retryPolicy 'on-idempotency-key' now sends one stable Idempotency-Key on every attempt (including the first) instead of rotating a fresh key per retry, so server-side dedup actually protects retried writes. Previously the key was generated in `onBeforeAttempt`, which only fires after a failure — so attempt 1 carried no key and each retry carried a brand-new one, meaning a lost-response-then-retry could double-apply the write (double create/publish/patch). The explicit `idempotencyKey` path is unchanged.
