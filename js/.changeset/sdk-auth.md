---
'@barkpark/core': minor
---

Added user authentication under `client.auth`: `register(email, password)`, `login(email, password, { totpCode? })` (returns `{ token, user }` — set the token on a new client for authenticated requests), `me()` (the current user, or `null` when not authenticated), and `logout()`. Supabase-style app-user auth over the server's `/v1/auth/*` endpoints (login returns the bearer session token in the body; MFA-enrolled accounts return `BarkparkAuthError` with code `mfa_required`). New types: `AuthUser`, `AuthSession`, `AuthRegisterResult`, `LoginOptions`, `BarkparkAuth`.
