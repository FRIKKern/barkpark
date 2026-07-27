// The network half of push registration: hand the device's native token to the
// Cloud control plane, once, per launch.
//
//   POST /v1/push/device-tokens   Bearer <cloud session>
//   {platform: "apns" | "fcm", token, metadata?}
//
// The server side already exists and is NOT rebuilt here: the route is an
// idempotent upsert on (user_id, platform, token), braked by a
// `push_register:<user_id>` bucket at 10/60s and capped at 20 device rows per
// user with revoked-first/stalest-next eviction. This module's whole job is to
// call it correctly and to SHUT UP when it cannot.
//
// ## Degrade honestly, never error-loop
//
// Every outcome is a typed result. In particular:
//
//   * `rate-limited` (429) — the server's own brake. Retrying immediately is
//     the exact behaviour the bucket exists to stop, so we do not; the next
//     launch re-registers (the upsert makes that free).
//   * `unauthorized` (401) — the Cloud session expired. Push registration is
//     not the right place to drive a re-login; the app's own session gate is.
//   * `rejected` (422) — the token was refused (bad platform, oversize). A
//     retry cannot help; a launch-loop of 422s would be pure noise.
//   * `unavailable` — no token to register at all (no `expo-notifications`, no
//     entitlement, no permission). The overwhelmingly common case today, and
//     the quietest: it is the app end of row-absence severability. No row is
//     written, so the fan-out selects nothing, so nothing fires. Zero flags.
//
// None of these throw. The single throwing path is a transport failure, and it
// is caught and mapped to `network-error` here, because a rejected promise in a
// launch effect is an unhandled rejection warning on every cold start.

export type RegisterPushResult =
  | { status: 'registered'; id: string; platform: 'apns' | 'fcm' }
  | { status: 'unavailable'; reason: string; detail?: string }
  | { status: 'rate-limited' }
  | { status: 'unauthorized' }
  | { status: 'rejected'; detail?: string }
  | { status: 'network-error'; detail: string }
  | { status: 'server-error'; httpStatus: number }

export interface CloudSessionRef {
  /** Cloud control-plane base URL (the app's stored `cloudUrl`). */
  url: string
  /** The Cloud SESSION token — not an instance app token. Registration is a
   * control-plane act: the device belongs to the USER, not to one instance. */
  token: string
}

export interface DeviceRegistration {
  platform: 'apns' | 'fcm'
  token: string
  /** Display-only device descriptors. Server-side these are never trusted for
   * routing — they exist so a human can tell two rows apart. */
  metadata?: Record<string, string>
}

export interface RegisterPushOptions {
  fetch?: typeof fetch
}

function normalizeBase(url: string): string {
  return url.trim().replace(/\/+$/, '')
}

/**
 * Register one device token with Cloud. Never throws.
 */
export async function registerDeviceToken(
  session: CloudSessionRef,
  registration: DeviceRegistration,
  options: RegisterPushOptions = {},
): Promise<RegisterPushResult> {
  const base = normalizeBase(session.url)
  if (!base || !session.token) {
    return { status: 'unavailable', reason: 'no-cloud-session' }
  }

  const fetchImpl = options.fetch ?? fetch

  let response: Response
  try {
    response = await fetchImpl(`${base}/v1/push/device-tokens`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: `Bearer ${session.token}`,
      },
      body: JSON.stringify({
        platform: registration.platform,
        token: registration.token,
        metadata: registration.metadata ?? {},
      }),
    })
  } catch (err) {
    return { status: 'network-error', detail: err instanceof Error ? err.message : String(err) }
  }

  if (response.status === 429) return { status: 'rate-limited' }
  if (response.status === 401) return { status: 'unauthorized' }

  let body: unknown
  try {
    body = await response.json()
  } catch {
    body = undefined
  }

  if (response.status === 422) {
    return { status: 'rejected', detail: errorCode(body) }
  }

  if (response.status < 200 || response.status >= 300) {
    return { status: 'server-error', httpStatus: response.status }
  }

  const record = (body ?? {}) as Record<string, unknown>
  const id = typeof record.id === 'string' ? record.id : ''
  if (!id) {
    // A 2xx without an id means the contract moved. Say so rather than
    // reporting a registration that may not exist.
    return { status: 'rejected', detail: 'missing id in 2xx response' }
  }

  return { status: 'registered', id, platform: registration.platform }
}

function errorCode(body: unknown): string | undefined {
  if (typeof body === 'object' && body !== null && 'error' in body) {
    const code = (body as { error: unknown }).error
    if (typeof code === 'string') return code
  }
  return undefined
}
