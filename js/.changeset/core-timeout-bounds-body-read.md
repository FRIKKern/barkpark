---
'@barkpark/core': patch
---

`timeoutMs` now bounds the whole request, body included. The per-attempt deadline timer was cleared the moment `fetch` resolved — i.e. when response HEADERS arrived — so a server that streamed headers and then stalled the body (slow-loris, half-open socket after headers) hung `request()` forever: the documented timeout never fired and the caller had no recourse short of wiring their own AbortSignal. The deadline now stays armed through the body read on both the ok path and the error-envelope decode, and a deadline abort that surfaces mid-body is reclassified as the `BarkparkTimeoutError` it is (retryable for reads, exactly like a stalled connection). A caller-initiated abort mid-body still re-throws its `AbortError` untouched. `rawResponse: true` keeps the old headers-only deadline — there the caller owns the body stream, and an export may legitimately outlive `timeoutMs`.
