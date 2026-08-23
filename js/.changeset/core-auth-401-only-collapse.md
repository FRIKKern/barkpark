---
"@barkpark/core": minor
---

`auth.me()` / `getCurrentUser` no longer report a refusal as an absent user: only a genuine 401 collapses to `null`. A 403 — including the server's `cors_forbidden` and `csrf_required` rejections (both emitted with status 403) — now propagates as `BarkparkAuthError` (status + serverCode intact) instead of reading as "no current user".
