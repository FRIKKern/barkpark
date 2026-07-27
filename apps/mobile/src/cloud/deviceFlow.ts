// Device-flow login engine — the mobile port of the CLI's runDeviceLoginFlow
// poll loop (internal/cli/login_device.go semantics): start a session, hand
// the caller the user code + approve URL to render, then poll until approved,
// denied, expired, or cancelled. Pure async logic with an injectable clock so
// tests run instantly; the UI layer owns rendering and Linking.
import type { CloudClient, DeviceStartResponse } from './api'
import { CloudApiError } from './api'

export type DeviceFlowOutcome =
  | { kind: 'approved'; token: string; teamId: string }
  | { kind: 'expired' }
  | { kind: 'denied'; code: string }
  | { kind: 'cancelled' }

export interface DeviceFlowHandle {
  /** The code pair + approve URL for the UI to render. */
  session: DeviceStartResponse
  /** Resolves with the terminal outcome of the poll loop. Never rejects on
   * an expected refusal — denials and expiries are outcomes. Transport
   * errors (network down) DO reject so the UI can offer a retry. */
  outcome: Promise<DeviceFlowOutcome>
  /** Stop polling (user backed out). The outcome resolves 'cancelled'. */
  cancel(): void
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

/**
 * Start a device-flow login and poll until terminal.
 *
 * Poll spacing follows the server's `interval`, widened by 5s on each
 * `slow_down` (RFC 8628 §3.5). The loop self-expires after `expires_in`
 * even if the server keeps answering pending — the code is dead by then.
 */
export async function startDeviceFlow(
  client: CloudClient,
  clientName: string,
  sleepImpl: (ms: number) => Promise<void> = sleep,
  now: () => number = Date.now,
): Promise<DeviceFlowHandle> {
  const session = await client.deviceStart(clientName)
  let cancelled = false
  // cancel() must win even against an in-flight sleep — the wait below races
  // the sleep against this promise so backing out is always immediate.
  let signalCancel: () => void = () => {}
  const cancelPromise = new Promise<void>((resolve) => {
    signalCancel = resolve
  })

  const outcome = (async (): Promise<DeviceFlowOutcome> => {
    let intervalMs = Math.max(1, session.interval) * 1000
    const deadline = now() + session.expiresIn * 1000
    for (;;) {
      if (cancelled) return { kind: 'cancelled' }
      if (now() >= deadline) return { kind: 'expired' }
      await Promise.race([sleepImpl(intervalMs), cancelPromise])
      if (cancelled) return { kind: 'cancelled' }
      let result
      try {
        result = await client.devicePoll(session.deviceCode)
      } catch (err) {
        if (err instanceof CloudApiError) {
          // Terminal refusal from the control plane — classify, stop the loop.
          if (err.code === 'expired_or_invalid' || err.code === 'expired_token') {
            return { kind: 'expired' }
          }
          return { kind: 'denied', code: err.code || `http_${err.status}` }
        }
        throw err // transport failure — surface for a retry affordance
      }
      switch (result.status) {
        case 'approved':
          return { kind: 'approved', token: result.token, teamId: result.teamId }
        case 'slow_down':
          intervalMs += 5000
          break
        case 'pending':
          break
      }
    }
  })()

  return {
    session,
    outcome,
    cancel() {
      cancelled = true
      signalCancel()
    },
  }
}
