---
'@barkpark/core': patch
---

Redact the auth token when a client is serialized. `createClient()` exposes the
frozen config as `client.config` with `token` an enumerable string, so
`JSON.stringify(client)`, `util.inspect(client)`, or a React Server Component ->
browser (React Flight) serialization would ship the raw auth token into logs or
HTML. The config now carries non-enumerable `toJSON` and Node `inspect` hooks
that replace a non-empty string `token` with `[REDACTED]` in every serialization
surface. `token` stays enumerable and direct `config.token` access (the
Authorization header path) still returns the real value, so auth and
`withConfig()`-derived clients are unaffected. Covered by a permanent four-vector
token-leak regression guard (`tests/token-leak-guard.test.ts`).
