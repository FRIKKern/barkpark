// Barkpark Cloud control-plane client — the mobile sibling of
// internal/cloudclient (Go). Same routes, same outcome mapping, transliterated
// so every branch is a COMPLETE typed outcome instead of a thrown string:
//
//   POST /v1/auth/device/start   — open a device-authorization session (unauthed)
//   POST /v1/auth/device/poll    — poll for approval (unauthed; the code IS the credential)
//   GET  /v1/barkparks?scope=all — the logged-in user's whole fleet (Bearer)
//   GET  /v1/barkparks/:id/credentials — admin token reveal (Bearer, team-gated)
//   POST /v1/barkparks/:id/app-token   — the member-reachable app-token mint
//                                        (Bearer; sibling slice mob-w1-token-exchange)
//
// Error philosophy mirrors the Go client: expected steady-states (pending,
// slow_down) and expected divergences (no_admin_token, app_token_unsupported)
// are RESULTS, not exceptions; only transport failures and unrecognised
// terminal refusals surface as CloudApiError.

export const DEFAULT_CLOUD_URL = 'https://api.barkpark.cloud'

export class CloudApiError extends Error {
  readonly status: number
  /** The control plane's machine error code (`{"error": "..."}`), '' when absent. */
  readonly code: string

  constructor(message: string, status: number, code: string) {
    super(message)
    this.name = 'CloudApiError'
    this.status = status
    this.code = code
  }
}

export interface DeviceStartResponse {
  deviceCode: string
  userCode: string
  verificationUri: string
  verificationUriComplete: string
  /** Minimum poll spacing, seconds. */
  interval: number
  /** Code TTL, seconds. */
  expiresIn: number
}

/** Approved carries the same {token, team_id} envelope a password login returns. */
export type DevicePollResult =
  | { status: 'pending' }
  | { status: 'slow_down' }
  | { status: 'approved'; token: string; teamId: string }

export interface CloudTeam {
  id: string
  name: string
  /** The caller's role in the owning team ('owner' | 'admin' | 'member' | ''). */
  role: string
}

/** One fleet row (the slice of cloudclient.Barkpark the app consumes). */
export interface CloudBarkpark {
  id: string
  name: string
  url: string
  host: string
  team: CloudTeam | null
}

export interface CloudCredentials {
  adminToken: string
  url: string
  host: string
}

/**
 * The app-token mint outcome (charter D8). `unsupported` is the CLOSED code
 * map for `409 {"error":"app_token_unsupported"}` (the Cloud proxy saw the
 * instance 404 the mint route) AND for a Cloud old enough to lack the proxy
 * route itself (404) — both mean "this pairing cannot mint yet", and the
 * caller falls back to manual token paste. Anything else is an error.
 */
export type AppTokenResult =
  | { kind: 'minted'; token: string; url: string; host: string }
  | { kind: 'unsupported' }

interface CloudFetchOptions {
  method: 'GET' | 'POST'
  path: string
  token?: string
  teamId?: string
  body?: unknown
}

export interface CloudClient {
  deviceStart(clientName: string): Promise<DeviceStartResponse>
  devicePoll(deviceCode: string): Promise<DevicePollResult>
  listAllBarkparks(): Promise<CloudBarkpark[]>
  getCredentialsForTeam(id: string, teamId: string): Promise<CloudCredentials>
  mintAppToken(id: string, teamId: string): Promise<AppTokenResult>
}

async function cloudFetch(
  baseUrl: string,
  fetchImpl: typeof fetch,
  opts: CloudFetchOptions,
): Promise<{ status: number; body: unknown }> {
  const headers: Record<string, string> = { Accept: 'application/json' }
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`
  if (opts.teamId) headers['X-Barkpark-Team'] = opts.teamId
  const init: RequestInit = { method: opts.method, headers }
  if (opts.body !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(opts.body)
  }
  const res = await fetchImpl(`${baseUrl.replace(/\/+$/, '')}${opts.path}`, init)
  let body: unknown
  try {
    body = await res.json()
  } catch {
    body = undefined
  }
  return { status: res.status, body }
}

function errorCode(body: unknown): string {
  if (typeof body === 'object' && body !== null && 'error' in body) {
    const code = (body as { error: unknown }).error
    if (typeof code === 'string') return code
  }
  return ''
}

function fail(what: string, status: number, body: unknown): never {
  const code = errorCode(body)
  throw new CloudApiError(`${what}: ${code || `http ${status}`}`, status, code)
}

const str = (v: unknown): string => (typeof v === 'string' ? v : '')
const num = (v: unknown, fallback: number): number =>
  typeof v === 'number' && Number.isFinite(v) ? v : fallback

/**
 * Build a Cloud control-plane client bound to one base URL + session token.
 * `fetchImpl` is injectable for tests; defaults to the global fetch (these
 * are plain JSON calls — no streaming — so RN's built-in fetch suffices).
 */
export function createCloudClient(config: {
  baseUrl?: string
  token?: string
  fetch?: typeof fetch
}): CloudClient {
  const baseUrl = config.baseUrl?.trim() || DEFAULT_CLOUD_URL
  const fetchImpl = config.fetch ?? fetch
  const token = config.token

  return {
    async deviceStart(clientName: string): Promise<DeviceStartResponse> {
      const body: Record<string, string> = {}
      if (clientName) body.client_name = clientName
      const res = await cloudFetch(baseUrl, fetchImpl, {
        method: 'POST',
        path: '/v1/auth/device/start',
        body,
      })
      if (res.status < 200 || res.status >= 300) fail('device start', res.status, res.body)
      const b = (res.body ?? {}) as Record<string, unknown>
      return {
        deviceCode: str(b.device_code),
        userCode: str(b.user_code),
        verificationUri: str(b.verification_uri),
        verificationUriComplete: str(b.verification_uri_complete),
        interval: num(b.interval, 5),
        expiresIn: num(b.expires_in, 600),
      }
    },

    async devicePoll(deviceCode: string): Promise<DevicePollResult> {
      const res = await cloudFetch(baseUrl, fetchImpl, {
        method: 'POST',
        path: '/v1/auth/device/poll',
        body: { device_code: deviceCode },
      })
      if (res.status >= 200 && res.status < 300) {
        // A 200 is either the pending steady-state or the approval —
        // discriminate BEFORE trusting a token (mirrors cloudclient.DevicePoll).
        const b = (res.body ?? {}) as Record<string, unknown>
        if (b.status === 'pending') return { status: 'pending' }
        const grantedToken = str(b.token)
        if (!grantedToken) {
          throw new CloudApiError(
            'device poll: 200 response carried neither a pending status nor a token',
            res.status,
            '',
          )
        }
        return { status: 'approved', token: grantedToken, teamId: str(b.team_id) }
      }
      // RFC-8628 spellings tolerated as aliases; slow_down widens the interval.
      switch (errorCode(res.body)) {
        case 'authorization_pending':
          return { status: 'pending' }
        case 'slow_down':
          return { status: 'slow_down' }
      }
      // expired_or_invalid / access_denied / anything unrecognised → stop the loop.
      fail('device poll', res.status, res.body)
    },

    async listAllBarkparks(): Promise<CloudBarkpark[]> {
      const res = await cloudFetch(baseUrl, fetchImpl, {
        method: 'GET',
        path: '/v1/barkparks?scope=all',
        token,
      })
      if (res.status < 200 || res.status >= 300) fail('list barkparks', res.status, res.body)
      const rows = ((res.body ?? {}) as { barkparks?: unknown[] }).barkparks ?? []
      return rows.map((row) => {
        const r = (row ?? {}) as Record<string, unknown>
        const t = r.team as Record<string, unknown> | null | undefined
        return {
          id: str(r.id),
          name: str(r.name),
          url: str(r.url),
          host: str(r.host),
          team: t ? { id: str(t.id), name: str(t.name), role: str(t.role) } : null,
        }
      })
    },

    async getCredentialsForTeam(id: string, teamId: string): Promise<CloudCredentials> {
      const res = await cloudFetch(baseUrl, fetchImpl, {
        method: 'GET',
        path: `/v1/barkparks/${encodeURIComponent(id)}/credentials`,
        token,
        teamId: teamId.trim() || undefined,
      })
      if (res.status < 200 || res.status >= 300) fail('get credentials', res.status, res.body)
      const b = (res.body ?? {}) as Record<string, unknown>
      return { adminToken: str(b.admin_token), url: str(b.url), host: str(b.host) }
    },

    async mintAppToken(id: string, teamId: string): Promise<AppTokenResult> {
      const res = await cloudFetch(baseUrl, fetchImpl, {
        method: 'POST',
        path: `/v1/barkparks/${encodeURIComponent(id)}/app-token`,
        token,
        teamId: teamId.trim() || undefined,
        body: {},
      })
      if (res.status >= 200 && res.status < 300) {
        const b = (res.body ?? {}) as Record<string, unknown>
        return { kind: 'minted', token: str(b.token), url: str(b.url), host: str(b.host) }
      }
      // Closed code map (charter D8): instance-can't-mint AND route-not-there
      // both resolve to the paste fallback, never a dead end.
      if (res.status === 409 && errorCode(res.body) === 'app_token_unsupported') {
        return { kind: 'unsupported' }
      }
      if (res.status === 404 && errorCode(res.body) === '') {
        return { kind: 'unsupported' }
      }
      fail('mint app token', res.status, res.body)
    },
  }
}
