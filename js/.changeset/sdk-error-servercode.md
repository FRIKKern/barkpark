---
'@barkpark/core': minor
---

Errors now carry `serverCode` — the server envelope's machine-readable `code` (e.g. `mfa_required`, `rev_mismatch`, `validation_failed`), distinct from `code` (which remains the error's class name for the cross-bundle `instanceof` fallback). The transport extracted this code for routing but discarded it, so callers couldn't tell e.g. `mfa_required` from `invalid_credentials` (both `BarkparkAuthError`) — needed to drive a two-step MFA login. Now `err.serverCode` exposes it on every error class.
