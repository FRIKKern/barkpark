---
'@barkpark/codegen': patch
---

`fetchSchema` is now bounded by a deadline that survives the body read. It gained `timeoutMs` (default `30_000` — the same read-request default `@barkpark/core`'s transport documents; `0` disables it), passes `AbortSignal.timeout(timeoutMs)` as the fetch signal, and races that signal against every awaited phase: the fetch itself, the `res.json()` body read, and the best-effort `res.text()` read on a non-2xx response.

Before this the call passed no signal at all and awaited both body reads unguarded, so a server that answered with headers and then stalled left `barkpark generate` waiting with no diagnostic, and an injected `fetchImpl` that never settled left the promise pending with no bound whatsoever. A deadline hit now rejects with `Schema fetch timed out after <ms>ms for <url>`; the existing missing-token, non-2xx, invalid-JSON and validation messages are unchanged.
