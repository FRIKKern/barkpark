// The OS half of push registration: ask the platform for THIS device's push
// token — and degrade honestly when it cannot be asked.
//
// The relay is severable by ABSENCE at every layer (charter D15), and this is
// the outermost one. Three things must be true before an OS will issue a token,
// and none of them exist in the app today:
//
//   1. `expo-notifications` is installed (it is NOT a dependency of
//      apps/mobile — deliberately: adding it changes the native build, which
//      belongs in the same wave as the entitlements, not before);
//   2. the build carries the platform push entitlement — iOS `aps-environment`,
//      Android `google-services.json` from the Firebase project whose service
//      account the control plane holds;
//   3. the user granted notification permission.
//
// So the honest answer today is `{status: 'unavailable'}` — a RESULT, not an
// error. No throw, no retry loop, no console noise on every launch. When the
// gate opens (see `Push.Adapters.NotConfigured` in cloud/ for exactly what a
// human supplies), the module is already here and starts returning tokens.
//
// `expo-notifications` is resolved through an INJECTABLE loader rather than a
// static `import`: a static import of a missing package is a Metro bundle-time
// failure, not a runtime `unavailable`. Same reason `@barkpark/core` is wired
// through config.fetch rather than assumed.

export type DeviceTokenResult =
  | {
      /** The OS issued a token. `platform` is the server's vocabulary, not RN's. */
      status: 'ok'
      platform: 'apns' | 'fcm'
      token: string
    }
  | {
      /**
       * No token, and that is FINE. `reason` is for a debug surface, never for
       * a user-facing error — the app works exactly as before without push.
       */
      status: 'unavailable'
      reason:
        | 'module-missing'
        | 'no-permission'
        | 'not-a-device'
        | 'unsupported-platform'
        | 'provider-error'
      detail?: string
    }

/** The slice of `expo-notifications` this module uses. */
export interface NotificationsModule {
  getPermissionsAsync(): Promise<{ status: string; canAskAgain?: boolean }>
  requestPermissionsAsync(): Promise<{ status: string }>
  getDevicePushTokenAsync(): Promise<{ type: string; data: unknown }>
}

/**
 * Load `expo-notifications` if it is installed. Returns null when it is not —
 * the module is an optional peer today, so a missing package must be a
 * runtime result, not a bundling failure.
 */
export type NotificationsLoader = () => NotificationsModule | null

export const defaultNotificationsLoader: NotificationsLoader = () => {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const mod = require('expo-notifications') as NotificationsModule | undefined
    return mod && typeof mod.getDevicePushTokenAsync === 'function' ? mod : null
  } catch {
    return null
  }
}

/**
 * `getDevicePushTokenAsync()` returns the NATIVE token — `{type: 'ios' | 'android'}`
 * — deliberately, not an Expo push token. The relay talks to APNs and FCM
 * directly with our own credentials (`Push.Adapters.APNS` / `.FCM`); an Expo
 * push token would route through Expo's servers instead, which is a different
 * product decision nobody made.
 */
function toServerPlatform(type: string): 'apns' | 'fcm' | null {
  if (type === 'ios') return 'apns'
  if (type === 'android') return 'fcm'
  return null
}

export interface DeviceTokenOptions {
  loadNotifications?: NotificationsLoader
  /** Ask the user if permission has not been decided yet. Default true. */
  requestPermission?: boolean
}

/**
 * Resolve this device's native push token, or say honestly why not.
 * Never throws — every failure path is a typed `unavailable`.
 */
export async function getDevicePushToken(
  options: DeviceTokenOptions = {},
): Promise<DeviceTokenResult> {
  const load = options.loadNotifications ?? defaultNotificationsLoader
  const notifications = load()
  if (!notifications) return { status: 'unavailable', reason: 'module-missing' }

  try {
    let permission = await notifications.getPermissionsAsync()
    if (permission.status !== 'granted' && (options.requestPermission ?? true)) {
      permission = await notifications.requestPermissionsAsync()
    }
    if (permission.status !== 'granted') {
      return { status: 'unavailable', reason: 'no-permission', detail: permission.status }
    }

    const native = await notifications.getDevicePushTokenAsync()
    const platform = toServerPlatform(native.type)
    if (!platform) {
      return { status: 'unavailable', reason: 'unsupported-platform', detail: native.type }
    }
    if (typeof native.data !== 'string' || native.data === '') {
      return { status: 'unavailable', reason: 'provider-error', detail: 'empty token' }
    }

    return { status: 'ok', platform, token: native.data }
  } catch (err) {
    // A simulator throws here ("must use a physical device"), as does a build
    // without the entitlement. Both are `unavailable`, never a crash.
    const detail = err instanceof Error ? err.message : String(err)
    const reason = /physical device|simulator|emulator/i.test(detail)
      ? 'not-a-device'
      : 'provider-error'
    return { status: 'unavailable', reason, detail }
  }
}
