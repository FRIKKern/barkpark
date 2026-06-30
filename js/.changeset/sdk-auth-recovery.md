---
'@barkpark/core': minor
---

Added email verification + password recovery to `client.auth`: `verifyEmail(token)` (confirm an address), `requestPasswordReset(email)` (send a reset email — always succeeds, no email-existence leak), and `resetPassword(token, password)` (set a new password; throws on an invalid/expired token, surfaced via `err.serverCode === 'invalid_token'`). Completes the SDK auth lifecycle — register → verify → login (+ MFA) → forgot/reset password — matching the CLI's `auth.*` commands.
