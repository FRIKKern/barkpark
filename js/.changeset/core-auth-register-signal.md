---
'@barkpark/core': patch
---

AbortSignal parity for auth: `client.auth.register()` now accepts an optional `{ signal }` last arg and threads it into the `POST /v1/auth/register` request, matching every other `client.auth.*` method (`login`, `me`, `logout`, MFA, email/password reset). A signup form that unmounts mid-request (route change, React StrictMode double-invoke) can now cancel the in-flight registration. Purely additive — existing callers are unaffected.
