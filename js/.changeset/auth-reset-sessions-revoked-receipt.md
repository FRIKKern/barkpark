---
'@barkpark/core': minor
---

`resetPassword()` now returns the reset receipt instead of `void`.

`POST /v1/auth/reset` has returned `{ok: true, sessionsRevoked: n}` since the
revoke-all-sessions count landed server-side, but the SDK requested `{ok:
boolean}` and returned `void`, discarding the count. A caller could not tell the
user how many other devices had just been signed out — the SDK receipt was
exactly the unread claim the API had just been changed to stop discarding.

`resetPassword()` now resolves with `PasswordResetReceipt`, whose
`sessionsRevoked` is `number | null`. `0` and `null` are deliberately different
facts: `0` means the server counted and there were no other sessions, while
`null` means the server reported no count at all (it predates the field), so
nothing was measured. Folding `null` into `0` would claim a measurement the
server never made.

This widens the return type from `void`, so existing callers that ignore the
result keep compiling; callers that explicitly annotated `Promise<void>` will
need to update the annotation.
