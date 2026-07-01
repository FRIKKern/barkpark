---
'@barkpark/core': patch
---

Internal: add a direct unit-test suite for the retry/backoff module (`retry.ts`) — the one core module that had no direct coverage. Pins the retry-classification rules (`defaultShouldRetry`: retry transient/transport + 5xx, never 4xx or statusless), the control flow (first-attempt success, give-up-after-maxAttempts, no-retry-on-non-retryable, custom `shouldRetry` override), and the `onBeforeAttempt(nextAttempt, prevError)` idempotency-key hook contract. No runtime change.
