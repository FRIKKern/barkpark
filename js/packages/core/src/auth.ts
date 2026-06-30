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
): Promise<AuthRegisterResult> {
  const { data } = await request<AuthRegisterResult>(config, `/v1/auth/register`, {
    method: 'POST',
    body: { email, password },
    kind: 'write',
  })
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
 * token. Returns `null` when not authenticated (401). Prefer `client.auth.me()`.
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
    if (err instanceof BarkparkAuthError) return null
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
