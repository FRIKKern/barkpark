---
'@barkpark/react': patch
---

`BarkparkReference`: the derived `client={bp}` fetcher now unwraps the raw `Response` returned by the real `@barkpark/core` client's `fetchRaw`. Previously it handed the `Response` object straight to the render prop as if it were the document, so the documented `client={bp}` usage rendered every reference empty (`author.name` was `undefined`). It now reads the `/v1/data/doc` envelope (`{ result: doc }`), returns `notFound` on non-ok responses, and still passes through stub fetchers that return an already-parsed object. The `BarkparkReferenceClient.fetchRaw` type is corrected to `<T = Response>` to match the core client, and the unused `doc?` member is dropped from the interface.
