// The push registration engine, composed: OS token → Cloud registration.
//
// Kept as ONE pure async function plus a thin hook so the whole policy is
// testable without React and without a device — the parts that can actually be
// wrong (the outcome mapping, the "register at most once per session" rule,
// the silence-on-unavailable rule) are all in `runPushRegistration`.
import { useEffect, useRef, useState } from 'react'

import {
  getDevicePushToken,
  type DeviceTokenOptions,
  type DeviceTokenResult,
} from './deviceToken'
import {
  registerDeviceToken,
  type CloudSessionRef,
  type RegisterPushOptions,
  type RegisterPushResult,
} from './registerDevice'

export type { DeviceTokenResult, RegisterPushResult, CloudSessionRef }
export { getDevicePushToken, registerDeviceToken }

export interface PushRegistrationOptions extends DeviceTokenOptions, RegisterPushOptions {
  /** Display-only device descriptors stored alongside the row. */
  metadata?: Record<string, string>
}

/**
 * Ask the OS for a token; if there is one, register it with Cloud. Returns the
 * registration outcome — `unavailable` (with the OS's reason) when there is no
 * token to register, which is today's expected state on every build.
 *
 * Never throws.
 */
export async function runPushRegistration(
  session: CloudSessionRef,
  options: PushRegistrationOptions = {},
): Promise<RegisterPushResult> {
  const device = await getDevicePushToken(options)
  if (device.status !== 'ok') {
    return { status: 'unavailable', reason: device.reason, detail: device.detail }
  }

  return registerDeviceToken(
    session,
    { platform: device.platform, token: device.token, metadata: options.metadata },
    options,
  )
}

/**
 * What the USER is told when this device is not registered for push.
 *
 * `registerDeviceToken` already computes an exemplary verdict — it refuses to
 * report `registered` on a 2xx whose body carries no id — and until now the
 * shell threw that verdict away, so a real 401/422/429 would have been as
 * silent as a healthy launch. Every non-registered outcome gets a line; only a
 * confirmed registration (and a verdict that has not landed yet, which claims
 * nothing) is silent.
 *
 * `unavailable` is deliberately included even though it is today's state on
 * every build (no `expo-notifications`, no entitlements — one human gate). A
 * phone that will never buzz when an agent blocks is a fact the owner of the
 * phone is entitled to; it is worded as a quiet statement, not an error.
 */
export function pushNotice(result: RegisterPushResult | undefined): string | undefined {
  if (result === undefined) return undefined // not attempted yet — no claim either way
  switch (result.status) {
    case 'registered':
      return undefined
    case 'unavailable':
      return 'Push is off on this device — nothing will alert you when an agent needs you.'
    case 'network-error':
      return 'Push is not set up: this device could not reach Barkpark Cloud.'
    case 'rate-limited':
      return 'Push is not set up yet: Cloud is rate-limiting registration. It retries on the next launch.'
    case 'unauthorized':
      return 'Push is not set up: Cloud refused your session. Sign out and back in to fix it.'
    case 'rejected':
      return 'Push is not set up: Cloud refused this device token.'
    case 'server-error':
      return `Push is not set up: Cloud returned HTTP ${result.httpStatus}.`
  }
}

/**
 * The app-side call site: register this device once per Cloud session.
 *
 * Keyed on `session.url + session.token` and guarded by a ref, so a re-render
 * (or the rollup poll's setState, which fires every 60s) cannot re-drive
 * registration. That guard is not cosmetic — the server's
 * `push_register:<user_id>` bucket is 10/60s, and the chat tab already shipped
 * one bug of exactly this family (`connectionFromConfig` re-created per render
 * → a welcome-frame storm). One attempt per session, and the next cold start
 * re-registers for free via the idempotent upsert.
 *
 * Returns the last outcome, and the shell RENDERS it through `pushNotice`: a
 * device without push is not an error state, but it is a state, and an app
 * that swallows its own verdict is claiming a push channel it never confirmed.
 */
export function usePushRegistration(
  session: CloudSessionRef | undefined,
  options: PushRegistrationOptions = {},
): RegisterPushResult | undefined {
  const [result, setResult] = useState<RegisterPushResult | undefined>(undefined)
  const attempted = useRef<string | undefined>(undefined)

  const key = session ? `${session.url}\n${session.token}` : undefined

  useEffect(() => {
    if (!session || !key) return
    if (attempted.current === key) return
    attempted.current = key

    let cancelled = false
    void runPushRegistration(session, options).then((outcome) => {
      if (!cancelled) setResult(outcome)
    })
    return () => {
      cancelled = true
    }
    // `options` is deliberately NOT a dependency: it is an inline object at the
    // call site, so depending on it would re-run this effect on every render —
    // the exact re-subscription bug the ref above exists to prevent. The key is
    // the session, which is what registration is actually about.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key])

  return result
}
