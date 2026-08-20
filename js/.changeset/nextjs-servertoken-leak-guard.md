---
'@barkpark/nextjs': patch
---

Test-only: lock the `serverToken` SAFE-by-construction verdict with a permanent regression guard (`servertoken-leak-guard.test.ts`). The nextjs SDK's server-only Bearer token is closure-captured — `defineLive`/`createBarkparkServer` return functions only, so a serialized server object never carries it. The guard asserts a sentinel `serverToken` (and client token) never surfaces in `JSON.stringify(server)`, `util.inspect(server)`, or `Object.keys(server)`, so a future refactor that hangs the token on the returned object turns red. No runtime change, no release.
