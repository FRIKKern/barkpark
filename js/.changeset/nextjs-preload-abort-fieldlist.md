---
'@barkpark/nextjs': patch
---

Three correctness fixes from the JS client audit (js-client-correctness-audit):

- `preloadDocument` (both the `Preloader` method and the one-shot export) now marks its fire-and-forget promise handled. A server that was down at preload time raised an `unhandledrejection` — process-fatal in default Node — turning a warm-up optimization into an outage. A later `loadDocument` for the same key still receives the original rejection.
- A caller-initiated abort of `barkparkFetch` re-throws its `AbortError` untouched (detect via `err.name === 'AbortError'`, exactly as with a bare fetch) instead of being mislabeled `BarkparkTimeoutError` — mirroring core transport's contract. A real `TimeoutError` (e.g. `AbortSignal.timeout`) still maps to `BarkparkTimeoutError`.
- `barkparkFetch`'s id-path `expand`/`fields` now fail closed like core's `getDoc`: a comma inside a field name throws (it silently split into extra expanded/projected fields — an over-broad read), entries are trimmed with empties dropped, and an empty list throws instead of silently omitting the param.
