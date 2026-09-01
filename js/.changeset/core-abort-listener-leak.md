---
'@barkpark/core': patch
---

`request()` no longer leaves a dead `abort` listener on the caller's `AbortSignal`. The transport wired the caller's signal into each attempt's `AbortController` with `{ once: true }`, which self-removes only if the signal actually FIRES — so a signal held across many requests (one `AbortController` per component or job, the documented usage) accumulated one dead handler per **attempt**: three from a single read that exhausted the retry policy, and Node's `EventTarget` starts warning past ten. The remover is now captured beside the `addEventListener` — the idiom `listen.ts` already uses for the same hazard — and run from an attempt-wide `finally`, so success, HTTP error, retry, timeout, a caller abort and a throwing `onBeforeRequest` hook all drop it. Abort propagation is unchanged: a caller abort still reaches the per-attempt signal handed to `fetch`.
