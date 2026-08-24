---
'@barkpark/core': patch
---

`exportDataset()` now uses the `fetch` you configured. `BarkparkClientConfig.fetch` is documented as the user override for MSW and tracing, and every other path in the package honours it — `transport.ts` for every JSON call, `listen.ts` for the SSE stream. `exportDataset`, the other stream, reached straight for the global.

Nothing errored. The request simply went out through a different door than the caller wired up: a test suite's mock was bypassed, a tracing wrapper saw no export traffic, an auth-injecting wrapper's header never went on. A dataset backup that quietly ignores your transport is the worst place for that to be true, and it was the only place it was.

Paid for by folding the response-guard ladder `export` and `listen` had each copied — auth check, ok check, body check, plus `listen`'s content-type check — into one `assertStreamResponse` beside the errors it raises. Every message, every error class, and the check ORDER are reproduced exactly, so a response failing two checks still reports the same one it reported before; that ordering is pinned by a test that reds when the checks are reordered. The two streaming paths now stay in step by construction. Net effect on the bundle: ESM 16 279 → 16 280 B, CJS 16 970 → 16 969 B.
