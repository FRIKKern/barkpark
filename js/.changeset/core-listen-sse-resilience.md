---
'@barkpark/core': patch
---

listen()/SSE: harden the realtime client against four reliability gaps.

- **Idle/keepalive watchdog** — a read timer is armed before every `reader.read()` and cleared by any byte (data or the server's `: keepalive` comment). On a half-open TCP socket (no data, no keepalive, no FIN) `read()` would previously hang forever, never erroring and never reconnecting; the watchdog now cancels the stuck reader and falls into the existing reconnect path. Default `75000` ms (2.5× the server's 30 s keepalive); tunable via the new `idleTimeoutMs` option (pass `0` to disable). Legitimate keepalive traffic never trips it.
- **Reconnect jitter** — both the exponential error backoff and the clean-close floor are now multiplied by a `0.5–1.0×` random factor, so a fleet no longer reconnects in lockstep after a server restart (thundering herd). The 8 s ceiling and the ~1 s busy-spin floor still hold.
- **Bounded decode buffer** — a stream that emits bytes with no frame boundary (`\n\n`) could grow the accumulation buffer without bound → OOM. The residual buffer is now capped at 1 MiB; past that a `BarkparkAPIError` is thrown instead of eating memory.
- **Clean-close escalation** — consecutive clean `200→EOF` closes that yield no data (a misconfigured proxy / instantly-terminating LB) previously looped silently forever. The client now counts them, resets on any data frame, and after 5 escalates to a thrown `BarkparkAPIError` so the caller eventually surfaces the fault (EventSource-parity hardening).

A healthy stream (normal keepalives + data) is unaffected — no spurious disconnects.
