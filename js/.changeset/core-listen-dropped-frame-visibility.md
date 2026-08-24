---
'@barkpark/core': patch
---

`listen()` now reports a dropped SSE frame instead of losing it silently. A frame whose `data:` payload does not parse as JSON is still skipped rather than crashing the subscription — killing a live stream over one corrupt event is worse than losing it — but the skip used to be reported on no channel at all: no throw, no callback, no counter, while the async iterator's "here is every event" contract stayed nominally true. A consumer doing cache revalidation on the stream went quietly stale with a green process and no log line.

The new optional `onDroppedFrame(raw, err)` listen option is called for each skipped frame with the raw `data:` text as received and the `JSON.parse` failure. Default behaviour is unchanged for healthy streams and for callers who pass no callback. A throw from the callback is swallowed, so a logging hook cannot take down a subscription.
