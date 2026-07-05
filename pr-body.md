## Step-up MFA — challenge sensitive actions (enterprise-ready-auth W2)

Implements the **decided** MFA enforcement model: **step-up on sensitive actions** (owner decision 2026-07-05), not org-wide-at-login. Lowest friction — matches the "easy choice for everyone" mandate and the Okta/WorkOS parity model: no MFA at login, a fresh-factor challenge only when you do something high-risk.

### What's new

The factor layer already existed (TOTP enrol/verify, replay-safe consume, recovery codes). This PR adds the **enforcement**:

- **Session freshness** — `user_sessions.mfa_verified_at` + `UserSession.mfa_fresh?/1` (10-min window, `default_step_up_window/0`).
- **`RequireRecentMfa` plug** — for a user who has MFA armed, a guarded action requires a fresh factor on this session or halts `401 mfa_required`. A user *without* MFA is never gated (opt-in, zero added friction).
- **`POST /v1/auth/mfa/step-up`** — present a current TOTP or one-time recovery code to make the session fresh, then retry the guarded action.
- **Freshness is stamped wherever a factor is proven** — login-with-TOTP/recovery mints an already-fresh session; enrolment-verify stamps the session; the step-up endpoint stamps it.
- **First guarded action: `POST /v1/auth/mfa/disable`** — stripping MFA now needs a fresh factor, not just the password, so a hijacked-but-unlocked session can't silently drop MFA. Recovery is preserved: a one-time recovery code satisfies step-up, and the token-based password reset still wipes MFA outright.
- **Audit** — every MFA event (`mfa_enrolled`, `mfa_challenged`, `mfa_passed`, `mfa_failed`, `mfa_disabled`) emits onto the tamper-evident chain.

### Scope

Criteria 1 (step-up gate), 2 (recovery codes as a step-up factor, single-use), and 4 (audit) of `era-w2-mfa-policy`. Criterion 3 (the optional org-wide `require_mfa` login overlay) is split to a focused follow-up — it needs a user→org resolution decision (a user can span orgs) that warrants its own change, matching how the first 16 PRs stayed one-capability each.

### Tests

Full suite green. New coverage: stale session challenged → step-up (TOTP) clears it → action succeeds; recovery code satisfies step-up and is single-use; non-enrolled user bypasses the gate; all MFA events land on an intact audit chain.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
