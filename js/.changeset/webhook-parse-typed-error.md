---
'@barkpark/core': patch
---

`parseWebhookEvent` now throws a typed `BarkparkAPIError` (`'malformed webhook body'`, with the raw `body` attached) on a non-JSON body instead of a bare `SyntaxError`. This matches every other decode path in the SDK (transport responses, error bodies, NDJSON export), so a webhook handler can catch parse failures with the same `instanceof BarkparkAPIError` check it already uses everywhere else.
