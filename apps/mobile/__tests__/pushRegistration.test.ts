/**
 * Push registration (charter D15) — the OS half, the network half, and the
 * composition.
 *
 * The behaviour under test is mostly about SILENCE: with no
 * `expo-notifications`, no entitlement, no permission, or a server brake, the
 * app must do nothing, loudly report nothing, and above all not loop. A relay
 * that is inert until a credential appears is the deliverable; an app that
 * retries a 429 on every render would be the opposite.
 */
import { getDevicePushToken, type NotificationsModule } from '../src/push/deviceToken'
import { registerDeviceToken } from '../src/push/registerDevice'
import { runPushRegistration } from '../src/push'

const session = { url: 'https://api.barkpark.cloud', token: 'session-token' }

function notifications(overrides: Partial<NotificationsModule> = {}): NotificationsModule {
  return {
    getPermissionsAsync: async () => ({ status: 'granted' }),
    requestPermissionsAsync: async () => ({ status: 'granted' }),
    getDevicePushTokenAsync: async () => ({ type: 'ios', data: 'apns-token-abc' }),
    ...overrides,
  }
}

function jsonResponse(status: number, body: unknown): Response {
  return {
    status,
    json: async () => body,
  } as unknown as Response
}

describe('getDevicePushToken', () => {
  it('is unavailable — not an error — when expo-notifications is not installed', async () => {
    // Today's real state on every build: the package is deliberately not a
    // dependency, because installing it changes the native build and belongs
    // in the same wave as the entitlements.
    const result = await getDevicePushToken({ loadNotifications: () => null })
    expect(result).toEqual({ status: 'unavailable', reason: 'module-missing' })
  })

  it('maps the NATIVE token type to the server platform vocabulary', async () => {
    const ios = await getDevicePushToken({ loadNotifications: () => notifications() })
    expect(ios).toEqual({ status: 'ok', platform: 'apns', token: 'apns-token-abc' })

    const android = await getDevicePushToken({
      loadNotifications: () =>
        notifications({ getDevicePushTokenAsync: async () => ({ type: 'android', data: 'fcm-t' }) }),
    })
    expect(android).toEqual({ status: 'ok', platform: 'fcm', token: 'fcm-t' })
  })

  it('requests permission once when undetermined, then proceeds', async () => {
    const request = jest.fn(async () => ({ status: 'granted' }))
    const result = await getDevicePushToken({
      loadNotifications: () =>
        notifications({
          getPermissionsAsync: async () => ({ status: 'undetermined', canAskAgain: true }),
          requestPermissionsAsync: request,
        }),
    })

    expect(request).toHaveBeenCalledTimes(1)
    expect(result.status).toBe('ok')
  })

  it('is unavailable when permission is denied — never a throw, never a retry', async () => {
    const request = jest.fn(async () => ({ status: 'denied' }))
    const result = await getDevicePushToken({
      loadNotifications: () =>
        notifications({
          getPermissionsAsync: async () => ({ status: 'denied', canAskAgain: false }),
          requestPermissionsAsync: request,
        }),
    })

    expect(result).toEqual({ status: 'unavailable', reason: 'no-permission', detail: 'denied' })
  })

  it('classifies the simulator refusal as not-a-device rather than a crash', async () => {
    const result = await getDevicePushToken({
      loadNotifications: () =>
        notifications({
          getDevicePushTokenAsync: async () => {
            throw new Error('Must use physical device for push notifications')
          },
        }),
    })

    expect(result.status).toBe('unavailable')
    expect(result).toMatchObject({ reason: 'not-a-device' })
  })

  it('refuses an unknown native platform instead of guessing apns', async () => {
    const result = await getDevicePushToken({
      loadNotifications: () =>
        notifications({ getDevicePushTokenAsync: async () => ({ type: 'web', data: 'x' }) }),
    })

    expect(result).toMatchObject({ status: 'unavailable', reason: 'unsupported-platform' })
  })
})

describe('registerDeviceToken', () => {
  it('POSTs the device token to the Cloud control plane as the session user', async () => {
    const fetchMock = jest.fn(async () => jsonResponse(201, { id: 'row-1', platform: 'apns' }))

    const result = await registerDeviceToken(
      session,
      { platform: 'apns', token: 'apns-token-abc', metadata: { model: 'iPhone 17' } },
      { fetch: fetchMock as unknown as typeof fetch },
    )

    expect(result).toEqual({ status: 'registered', id: 'row-1', platform: 'apns' })

    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(url).toBe('https://api.barkpark.cloud/v1/push/device-tokens')
    expect(init.method).toBe('POST')
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer session-token')
    expect(JSON.parse(init.body as string)).toEqual({
      platform: 'apns',
      token: 'apns-token-abc',
      metadata: { model: 'iPhone 17' },
    })
  })

  it('does not call the server at all without a Cloud session', async () => {
    const fetchMock = jest.fn()
    const result = await registerDeviceToken(
      { url: '', token: '' },
      { platform: 'apns', token: 't' },
      { fetch: fetchMock as unknown as typeof fetch },
    )

    expect(result).toEqual({ status: 'unavailable', reason: 'no-cloud-session' })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('reports the server brake as rate-limited and does NOT retry it', async () => {
    // The server bucket is push_register:<user_id> at 10/60s. Retrying inside
    // the window is the behaviour the bucket exists to stop; the next cold
    // start re-registers for free through the idempotent upsert.
    const fetchMock = jest.fn(async () => jsonResponse(429, { error: 'rate_limited' }))

    const result = await registerDeviceToken(
      session,
      { platform: 'apns', token: 't' },
      { fetch: fetchMock as unknown as typeof fetch },
    )

    expect(result).toEqual({ status: 'rate-limited' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('maps 401 and 422 to typed results, not exceptions', async () => {
    const unauthorized = await registerDeviceToken(
      session,
      { platform: 'apns', token: 't' },
      { fetch: (async () => jsonResponse(401, { error: 'unauthorized' })) as unknown as typeof fetch },
    )
    expect(unauthorized).toEqual({ status: 'unauthorized' })

    const rejected = await registerDeviceToken(
      session,
      { platform: 'apns', token: 't' },
      { fetch: (async () => jsonResponse(422, { error: 'invalid' })) as unknown as typeof fetch },
    )
    expect(rejected).toEqual({ status: 'rejected', detail: 'invalid' })
  })

  it('catches a transport failure — an unhandled rejection on every cold start is not acceptable', async () => {
    const result = await registerDeviceToken(
      session,
      { platform: 'apns', token: 't' },
      {
        fetch: (async () => {
          throw new Error('Network request failed')
        }) as unknown as typeof fetch,
      },
    )

    expect(result).toEqual({ status: 'network-error', detail: 'Network request failed' })
  })

  it('treats a 2xx without an id as a contract break rather than a silent success', async () => {
    const result = await registerDeviceToken(
      session,
      { platform: 'apns', token: 't' },
      { fetch: (async () => jsonResponse(201, { registered: true })) as unknown as typeof fetch },
    )

    expect(result).toMatchObject({ status: 'rejected' })
  })
})

describe('runPushRegistration', () => {
  it('never reaches the network when the OS has no token to give', async () => {
    // The end-to-end shape of severability at the app layer: no module, no
    // token, no request, no row — and therefore nothing for the relay to fan
    // out to. No flag was consulted anywhere in that chain.
    const fetchMock = jest.fn()

    const result = await runPushRegistration(session, {
      loadNotifications: () => null,
      fetch: fetchMock as unknown as typeof fetch,
    })

    expect(result).toEqual({ status: 'unavailable', reason: 'module-missing', detail: undefined })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('registers the token the OS gave, carrying the platform through', async () => {
    const fetchMock = jest.fn(async () => jsonResponse(201, { id: 'row-9', platform: 'fcm' }))

    const result = await runPushRegistration(session, {
      loadNotifications: () =>
        notifications({ getDevicePushTokenAsync: async () => ({ type: 'android', data: 'fcm-9' }) }),
      fetch: fetchMock as unknown as typeof fetch,
      metadata: { app: '0.1.0' },
    })

    expect(result).toEqual({ status: 'registered', id: 'row-9', platform: 'fcm' })
    const [, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit]
    expect(JSON.parse(init.body as string)).toEqual({
      platform: 'fcm',
      token: 'fcm-9',
      metadata: { app: '0.1.0' },
    })
  })
})
