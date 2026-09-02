fix(core): listen() escalates consecutive malformed SSE frames, so a caller with no callback is no longer silently starved (#14720)

onDroppedFrame (#13581) reported each skipped frame, but it is opt-in: a caller
who passes no callback still took unbounded silent loss while the iterator's
"here is every event" contract stayed nominally true. Ten CONSECUTIVE unusable
frames now throw a BarkparkAPIError naming repeated malformed frames.

The counter resets on a healthy DATA frame and deliberately NOT on a keepalive
-- a keepalive is evidence about the socket and none about the encoder, so a
server emitting garbage on its normal keepalive cadence cannot pin the counter
below the threshold forever. It survives reconnects for the same reason: a
reconnect does not re-encode anything.

It stays ARMED under maxReconnects:'unbounded', unlike the clean-close
escalation: a clean close is a transport symptom a retry can outlast, an
encoder emitting garbage is a producer defect no retry fixes. That asymmetry
also fixes a mis-attribution -- a malformed-only stream used to raise
"listen: repeated empty stream closes", blaming the transport for an encoder
defect on a stream that was never empty. The existing red-adjacent test that
pinned that wrong cause is flipped rather than re-derived.

Bundle budget re-measured with pnpm run build immediately before each pnpm size:
  before  CJS 17.08 kB / 17.5 kB    ESM 16.38 kB / 16.5 kB
  after   CJS 17.11 kB / 17.5 kB    ESM 16.41 kB / 16.5 kB
Fits under the existing caps; no cap was raised.

Task: task-a4ad081d07a2e203
