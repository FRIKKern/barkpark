---
'@barkpark/core': patch
---

`listen()` now floors the reconnect after a clean stream close at 1s, preventing a zero-delay reconnect storm against endpoints that answer 200 then immediately EOF. A misconfigured proxy or instantly-terminating load balancer that responds `200 text/event-stream` and closes the body with no frames previously drove an unbounded zero-delay reconnect loop — clean closes don't count against `maxReconnects` and the backoff counter resets on every successful open, so the client busy-spun, pegging CPU and hammering the server. This mirrors the existing 1s floor on the Go apiclient side (`internal/apiclient/change.go`).
