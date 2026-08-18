---
'@barkpark/nextjs': patch
---

Guard the `runFetch` ok-path (server boundary) against 204/empty/non-JSON bodies. It now
mirrors the `@barkpark/core` transport ok-path: a 204 or empty 2xx body resolves to
`undefined` (success), and a non-JSON 2xx body throws a `BarkparkAPIError` instead of a raw
`SyntaxError` that would escape the Barkpark error taxonomy.
