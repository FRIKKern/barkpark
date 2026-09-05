// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// User authentication — register / login / me / logout against the global
// (pre-tenant) `/v1/auth/*` endpoints. login returns a bearer SESSION TOKEN in
// the body; feed it back as a new client's `token` to make authenticated reads.
// No `scopePrefix` here — these routes are not scoped to a workspace/project.

import { request } from './transport'
import { BarkparkAuthError } from './errors'
import type {
  BarkparkClientConfig,
  AuthUser,
  AuthSession,
  AuthRegisterResult,
  LoginOptions,
  MfaEnrollResult,
  MfaVerifyResult,
  PasswordResetReceipt,
} from './types'

/**
 * Register a new user (`POST /v1/auth/register`). The response is deliberately
 * generic (the server never reveals whether the email already existed). Prefer
 * `client.auth.register()`.
 */
export async function registerUser(
  config: BarkparkClientConfig,
  email: string,
  password: string,
  opts?: { signal?: AbortSignal },
): Promise<AuthRegisterResult> {
  const reqOpts: { method: 'POST'; body: { email: string; password: string }; kind: 'write'; signal?: AbortSignal } = {
    method: 'POST',
    body: { email, password },
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<AuthRegisterResult>(config, `/v1/auth/register`, reqOpts)
  return data
}

/**
 * Log in (`POST /v1/auth/login`). Returns `{ token, user }` — set `token` on a
 * new client to make authenticated requests. Throws `BarkparkAuthError` on bad
 * credentials, or with code `mfa_required` when the account needs a TOTP code
 * (pass `totpCode` / `recoveryCode` and retry). Prefer `client.auth.login()`.
 */
export async function loginUser(
  config: BarkparkClientConfig,
  email: string,
  password: string,
  opts?: LoginOptions,
): Promise<AuthSession> {
  const body: { email: string; password: string; totp_code?: string; recovery_code?: string } = {
    email,
    password,
  }
  if (opts?.totpCode !== undefined) body.totp_code = opts.totpCode
  if (opts?.recoveryCode !== undefined) body.recovery_code = opts.recoveryCode
  const reqOpts: { method: 'POST'; body: typeof body; kind: 'write'; signal?: AbortSignal } = {
    method: 'POST',
    body,
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<AuthSession>(config, `/v1/auth/login`, reqOpts)
  return data
}

/**
 * The current authenticated user (`GET /v1/auth/me`), using the client's session
 * token. Returns `null` only for a genuine 401 (not authenticated). A 403 —
 * including the server's `cors_forbidden` and `csrf_required` rejections, both
 * emitted with status 403 — propagates as `BarkparkAuthError`: a token that
 * lacks permission, or a CORS/CSRF refusal, is a refusal-to-answer, not an
 * absent user. Prefer `client.auth.me()`.
 */
export async function getCurrentUser(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<AuthUser | null> {
  const reqOpts: { kind: 'read'; signal?: AbortSignal } = { kind: 'read' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  try {
    const { data } = await request<{ user?: AuthUser }>(config, `/v1/auth/me`, reqOpts)
    return data.user ?? null
  } catch (err) {
    // Only the genuine "who are you? — nobody" answer collapses to null.
    // transport.ts throws BarkparkAuthError for 401 AND 403/cors_forbidden/
    // csrf_required (all 403 server-side); discriminating on status keeps a
    // refusal from being reported as "no current user".
    if (err instanceof BarkparkAuthError && err.status === 401) return null
    throw err
  }
}

/** Revoke the current session (`DELETE /v1/auth/logout`). Prefer `client.auth.logout()`. */
export async function logoutUser(
  config: BarkparkClientConfig,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  const reqOpts: { method: 'DELETE'; kind: 'write'; signal?: AbortSignal } = {
    method: 'DELETE',
    kind: 'write',
  }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ ok: boolean }>(config, `/v1/auth/logout`, reqOpts)
}

// ── TOTP MFA ────────────────────────────────────────────────────────────────
// All three RE-AUTH: the server pattern-matches `password` in the body (the
// session token alone isn't enough for account-security changes), so each takes
// the account password and 422s without it.

/**
 * Begin TOTP MFA enrolment (`POST /v1/auth/mfa/enroll`). Returns the base32
 * `secret`, the `otpauth_uri`, and a pre-rendered `qr_svg` to show in an
 * authenticator app — then confirm with {@link verifyMfa}. Prefer
 * `client.auth.enrollMfa()`.
 */
export async function enrollMfa(
  config: BarkparkClientConfig,
  password: string,
  opts?: { signal?: AbortSignal },
): Promise<MfaEnrollResult> {
  const reqOpts: {
    method: 'POST'
    body: { password: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { password }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MfaEnrollResult>(config, `/v1/auth/mfa/enroll`, reqOpts)
  return data
}

/**
 * Confirm TOTP enrolment with the `secret` + a current `code`
 * (`POST /v1/auth/mfa/verify`). Returns `{ ok, recovery_codes }` — surface the
 * recovery codes to the user ONCE. Prefer `client.auth.verifyMfa()`.
 */
export async function verifyMfa(
  config: BarkparkClientConfig,
  secret: string,
  code: string,
  password: string,
  opts?: { signal?: AbortSignal },
): Promise<MfaVerifyResult> {
  const reqOpts: {
    method: 'POST'
    body: { secret: string; code: string; password: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { secret, code, password }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<MfaVerifyResult>(config, `/v1/auth/mfa/verify`, reqOpts)
  return data
}

/** Disable TOTP MFA on the account (`POST /v1/auth/mfa/disable`). Prefer `client.auth.disableMfa()`. */
export async function disableMfa(
  config: BarkparkClientConfig,
  password: string,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  const reqOpts: {
    method: 'POST'
    body: { password: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { password }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ ok: boolean }>(config, `/v1/auth/mfa/disable`, reqOpts)
}

// ── Email verification + password recovery ───────────────────────────────────
// Public (no token). Success = no throw; an invalid/expired token surfaces as a
// thrown error (a 422 with serverCode `invalid_token` → BarkparkAuthError).

/**
 * Confirm an email address with the token from the verification email
 * (`POST /v1/auth/verify-email`). Throws on an invalid/expired token. Prefer
 * `client.auth.verifyEmail()`.
 */
export async function verifyEmail(
  config: BarkparkClientConfig,
  token: string,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  const reqOpts: { method: 'POST'; body: { token: string }; kind: 'write'; signal?: AbortSignal } =
    { method: 'POST', body: { token }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ ok: boolean }>(config, `/v1/auth/verify-email`, reqOpts)
}

/**
 * Request a password-reset email (`POST /v1/auth/request-reset`). Always succeeds
 * (the server never reveals whether the email exists). Prefer
 * `client.auth.requestPasswordReset()`.
 */
export async function requestPasswordReset(
  config: BarkparkClientConfig,
  email: string,
  opts?: { signal?: AbortSignal },
): Promise<void> {
  const reqOpts: { method: 'POST'; body: { email: string }; kind: 'write'; signal?: AbortSignal } =
    { method: 'POST', body: { email }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  await request<{ ok: boolean }>(config, `/v1/auth/request-reset`, reqOpts)
}

/**
 * Set a new password using a reset token (`POST /v1/auth/reset`). Throws on an
 * invalid/expired token (serverCode `invalid_token`). Prefer
 * `client.auth.resetPassword()`.
 *
 * Returns the reset receipt. A successful reset revokes every other session for
 * the user, and `sessionsRevoked` is how many the server actually stamped.
 *
 * `sessionsRevoked` is `number | null`, and the two are NOT the same fact:
 * `0` means the server counted and there were no other sessions to kill;
 * `null` means the server did not report a count at all (it predates the field),
 * so the caller does not know. Folding the second into `0` would re-introduce
 * exactly the unread receipt this endpoint was changed to stop discarding —
 * a caller showing "0 other devices signed out" when nothing was measured is
 * making a claim the server never made.
 */
export async function resetPassword(
  config: BarkparkClientConfig,
  token: string,
  password: string,
  opts?: { signal?: AbortSignal },
): Promise<PasswordResetReceipt> {
  const reqOpts: {
    method: 'POST'
    body: { token: string; password: string }
    kind: 'write'
    signal?: AbortSignal
  } = { method: 'POST', body: { token, password }, kind: 'write' }
  if (opts?.signal !== undefined) reqOpts.signal = opts.signal
  const { data } = await request<{ ok: boolean; sessionsRevoked?: number }>(
    config,
    `/v1/auth/reset`,
    reqOpts,
  )
  return {
    sessionsRevoked: typeof data?.sessionsRevoked === 'number' ? data.sessionsRevoked : null,
  }
}
