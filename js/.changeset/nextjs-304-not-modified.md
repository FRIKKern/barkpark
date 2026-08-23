---
'@barkpark/nextjs': patch
---

`barkparkFetch` resolves `undefined` on a 304 Not Modified instead of throwing a generic `BarkparkAPIError`. A 304 is `ok === false` with an empty body, so it fell into the error decoder — an error thrown at the one caller who explicitly opted into conditional semantics. The SDK never sends `If-None-Match`/`If-Modified-Since` itself and Next's data cache revalidates by refetching, so a 304 is reachable only when the consumer injects a conditional header via `fetchOptions.headers` — and that caller holds the copy the 304 says is still current. It joins the existing no-body success family (204 / empty body → `undefined`): "not modified, keep your copy."
