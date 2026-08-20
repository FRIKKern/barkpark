# V8 — listen.ts frame-parser tail: SSE buffer cap + keepalive/cleanCloseCount

Verdict: SAFE. Zero findings. Both robustness questions answered on origin/main.

## Q1 — is no-delimiter SSE frame growth bounded? YES

Cap DEFINED at `js/packages/core/src/listen.ts:39`:
`const MAX_SSE_BUFFER_BYTES = 1_048_576` (1 MiB).

Cap ENFORCED at `:343`, after the frame-drain while-loop, each read iteration:
`if (buffer.length > MAX_SSE_BUFFER_BYTES) throw new BarkparkAPIError('listen: SSE buffer overflow (no frame boundary)')`.

A stream emitting bytes with no `\n\n`/`\r\n\r\n` boundary grows `buffer` (`:296` `buffer += decoder.decode(...)`) but the residual check fires every iteration → bounded to ~1 MiB + one read chunk, then throws into the reconnect/error path. NOT unbounded. Memory-DoS class closed.

Inner drain loop (`:299` `while (frameEnd !== -1)`) also cannot infinite-loop: `buffer = buffer.slice(frameEnd.end)` (`:302`) advances the cursor BEFORE parse, so even a null-parse frame shrinks the buffer; loop terminates when no boundary remains.

## Q2 — keepalive vs cleanCloseCount

The assignment premise ("correctly AVOID resetting") is INVERTED vs the shipped design, and the shipped design is correct.

Pure comment/keepalive branch (`:315-320`, `dataLines.length === 0`) INTENTIONALLY sets `cleanCloseCount = 0`. Constant comment `:44-46` and inline comment `:311-317` state the rationale: a keepalive proves a real live stream, so it resets the silent-close escalation in both modes; an instantly-terminating LB (the failure the guard targets) never emits a 30s-cadence keepalive, so the detector keeps its teeth against the actual DoS shape. Without the reset, five 75s idle-watchdog cycles over a quiet board would kill a healthy stream.

Escalation still fires for the real failure: consecutive clean 200→EOF closes with ZERO frames between them never reset the counter → `:362` `cleanCloseCount++`, `:363` throws at `MAX_CONSECUTIVE_CLEAN_CLOSES = 5` (unless `unbounded`).

Adversarial edge (noted, not a bug): a hostile server sending exactly one keepalive then EOF per connection resets the counter each cycle and evades the ×5 throw — but the reconnect is floored at 1s (`cleanCloseFloor = Math.max(reconnectBase, 1000)`, `:374`) with jitter, so worst case is ~1 req/s indefinitely, matching documented EventSource retry-forever parity for streams showing signs of life. Bounded, no busy-spin, no crash, no OOM. Considered tradeoff, not a correctness defect.

## Rerun
```
git show origin/main:js/packages/core/src/listen.ts | sed -n '35,55p'      # constant defs
git show origin/main:js/packages/core/src/listen.ts | sed -n '280,345p'    # drain loop + cap enforce
git show origin/main:js/packages/core/src/listen.ts | sed -n '308,320p'    # keepalive reset branch
```
