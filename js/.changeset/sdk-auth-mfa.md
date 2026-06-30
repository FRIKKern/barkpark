---
'@barkpark/core': minor
---

Added TOTP MFA to `client.auth`: `enrollMfa(password)` (returns the base32 `secret`, `otpauth_uri`, and a pre-rendered `qr_svg` to show in an authenticator app), `verifyMfa(secret, code, password)` (returns `{ ok, recovery_codes }`), and `disableMfa(password)`. All three re-auth with the account password (the server requires it for account-security changes, not just a session token) — completing the SDK auth surface to match the CLI's `bp auth mfa-*` commands. New types: `MfaEnrollResult`, `MfaVerifyResult`.
