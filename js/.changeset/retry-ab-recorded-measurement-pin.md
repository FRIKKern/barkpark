---
'@barkpark/core': patch
---

The interleaved A/B that justifies the narrow retry policy is now pinned to the constants it measured. The numbers — 27/40 for the old wide policy against 32/40 for the narrowed, budget-checked one on a sick-and-slow box — lived only in a PR body and a ledger stamp, and both harness arms sit behind `BARKPARK_RETRY_AB`, so no CI run ever re-took them: moving `MIN_ATTEMPT_BUDGET_MS`, `RETRYABLE_SERVER_CODE`, `MAX_RATE_LIMIT_BACKOFF_MS` or any of the three `RetryPolicy` objects turned the justification into a statement about code that no longer shipped, silently. A not-gated test now diffs the live policy inputs against a hand-typed transcript (`tests/retry-ab.recorded.ts`, which imports nothing, so its expectation cannot be read out of the thing it guards) and reds with the exact command to re-run the harness. No runtime behaviour changes and no bytes reach the bundle — the pin is test-only.
