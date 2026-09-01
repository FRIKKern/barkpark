---
'@barkpark/core': patch
---

`listen()` now escalates a run of malformed SSE frames instead of losing them silently when no `onDroppedFrame` callback is passed. The callback shipped the per-frame report, but it is opt-in: a caller who passes none still took unbounded silent loss while the async iterator's "here is every event" contract stayed nominally true.

Ten CONSECUTIVE unusable frames now throw a `BarkparkAPIError` naming repeated malformed frames. The counter resets on a healthy `data:` frame and deliberately NOT on a keepalive — a keepalive proves the socket is alive and nothing about the encoder, so a server emitting garbage on its normal keepalive cadence cannot pin the counter below the threshold forever. It also survives reconnects, because a reconnect does not re-encode anything.

Unlike the consecutive-clean-close escalation, this one stays ARMED under `maxReconnects: 'unbounded'`: a clean close is a transport symptom a retry can outlast, while an encoder emitting garbage is a producer defect no retry fixes. Previously such a stream eventually raised `listen: repeated empty stream closes` — blaming the transport for an encoder defect, on a stream that was never empty. Healthy streams are unaffected.
