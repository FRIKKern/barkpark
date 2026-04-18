'use client'
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import {
  createContext,
  useContext,
  useEffect,
  type JSX,
  type ReactNode,
} from 'react'
import { useRouter } from 'next/navigation'
import { BarkparkEdgeRuntimeError, type BarkparkClient } from '@barkpark/core'

const DEBOUNCE_MS = 500
const DEV_FIRST_EVENT_WARN_MS = 5000

/** ADR-005 — three independent edge-runtime detectors. Returns the matched signal name or null. */
export function detectEdgeRuntime(): string | null {
  if (typeof (globalThis as { EdgeRuntime?: unknown }).EdgeRuntime !== 'undefined') {
    return 'globalThis.EdgeRuntime'
  }
  if (typeof process !== 'undefined' && (process as { env?: Record<string, string | undefined> }).env?.NEXT_RUNTIME === 'edge') {
    return 'process.env.NEXT_RUNTIME==="edge"'
  }
  if (typeof ReadableStream !== 'undefined' && typeof process === 'undefined') {
    return 'globalThis.ReadableStream && !process'
  }
  return null
}

function assertNotEdge(): void {
  const detected = detectEdgeRuntime()
  if (detected !== null) {
    throw new BarkparkEdgeRuntimeError(
      `@barkpark/nextjs <BarkparkLive /> requires the Node.js runtime; detected ${detected}. Add 'export const runtime = "nodejs"' to your route segment.`,
    )
  }
}

const ClientContext = createContext<BarkparkClient | null>(null)

export interface BarkparkLiveProps {
  /** Override the client provided via BarkparkLiveProvider. */
  client?: BarkparkClient
  /** Debounce window for router.refresh() in ms. Default 500. */
  debounceMs?: number
  /** Dev-only "no SSE event in N ms" warning. 0 disables. Default 5000. */
  devWarnMs?: number
}

/**
 * Mounts a server-sent-events subscription to the configured Barkpark client and
 * triggers a debounced `router.refresh()` on each event. Renders nothing.
 *
 * Edge guard: throws synchronously in render AND inside the subscription on detection
 * (ADR-005 — three-layer detector). Pair with `createBarkparkServer().defineLive`
 * so the client prop is pre-bound, or wrap in {@link BarkparkLiveProvider}.
 *
 * @param props — Optional overrides; the client must be provided here or via provider.
 * @returns `null` — this component renders nothing.
 * @throws {@link BarkparkEdgeRuntimeError} when mounted in an edge runtime.
 *
 * @example
 * // app/layout.tsx
 * import { BarkparkLive } from '@barkpark/nextjs/client'
 * import { client } from '@/lib/barkpark-client'
 *
 * export default function RootLayout({ children }) {
 *   return <html><body>{children}<BarkparkLive client={client} /></body></html>
 * }
 */
export function BarkparkLive(props: BarkparkLiveProps = {}): null {
  // Layer 1 of edge guard — fires synchronously during render so misuse fails loudly.
  assertNotEdge()

  const router = useRouter()
  const ctxClient = useContext(ClientContext)
  const client = props.client ?? ctxClient
  const debounceMs = props.debounceMs ?? DEBOUNCE_MS
  const devWarnMs = props.devWarnMs ?? DEV_FIRST_EVENT_WARN_MS

  useEffect(() => {
    if (client === null) return undefined
    return startLiveSubscription({
      client,
      refresh: () => {
        router.refresh()
      },
      debounceMs,
      devWarnMs,
    })
  }, [client, router, debounceMs, devWarnMs])

  return null
}

export interface BarkparkLiveProviderProps {
  client: BarkparkClient
  children?: ReactNode
  debounceMs?: number
  devWarnMs?: number
}

/**
 * Wraps the tree in a BarkparkClient context and mounts a single
 * `<BarkparkLive />`. `useEffect` cleanup tears down the SSE subscription so
 * HMR / route changes do not leak connections.
 *
 * @param props — {@link BarkparkLiveProviderProps}; `client` required.
 *
 * @example
 * // app/layout.tsx
 * import { BarkparkLiveProvider } from '@barkpark/nextjs/client'
 * import { client } from '@/lib/barkpark-client'
 *
 * export default function RootLayout({ children }) {
 *   return (
 *     <html><body>
 *       <BarkparkLiveProvider client={client} debounceMs={750}>
 *         {children}
 *       </BarkparkLiveProvider>
 *     </body></html>
 *   )
 * }
 */
export function BarkparkLiveProvider(props: BarkparkLiveProviderProps): JSX.Element {
  const liveProps: BarkparkLiveProps = { client: props.client }
  if (props.debounceMs !== undefined) liveProps.debounceMs = props.debounceMs
  if (props.devWarnMs !== undefined) liveProps.devWarnMs = props.devWarnMs
  return (
    <ClientContext.Provider value={props.client}>
      <BarkparkLive {...liveProps} />
      {props.children}
    </ClientContext.Provider>
  )
}

export interface StartLiveOpts {
  client: BarkparkClient
  refresh: () => void
  debounceMs?: number
  devWarnMs?: number
}

function isProductionEnv(): boolean {
  return typeof process !== 'undefined' && (process as { env?: Record<string, string | undefined> }).env?.NODE_ENV === 'production'
}

type HotApi = { dispose?: (cb: () => void) => void }

function getHotApi(): HotApi | undefined {
  try {
    const meta = import.meta as unknown as { hot?: HotApi }
    if (meta?.hot !== undefined) return meta.hot
  } catch {
    /* noop */
  }
  try {
    const m = (globalThis as unknown as { module?: { hot?: HotApi } }).module
    if (m?.hot !== undefined) return m.hot
  } catch {
    /* noop */
  }
  return undefined
}

/**
 * Pure SSE subscription helper — returned teardown clears timers and calls handle.unsubscribe().
 * Exported (no React deps) so unit tests can drive it directly.
 *
 * Layer 2 of the edge guard — duplicate of the render-time check so callers wiring this
 * directly (e.g. from a non-React surface) are also protected.
 *
 * Teardown triggers: caller invokes returned fn, `beforeunload` fires, HMR dispose fires.
 * Core's client.listen() owns exponential-backoff reconnect (ADR-005), so this layer
 * only coordinates React/lifecycle teardown.
 */
export function startLiveSubscription(opts: StartLiveOpts): () => void {
  assertNotEdge()
  const debounceMs = opts.debounceMs ?? DEBOUNCE_MS
  const devWarnMs = opts.devWarnMs ?? DEV_FIRST_EVENT_WARN_MS

  let disposed = false
  let firstEventReceived = false
  let timerId: ReturnType<typeof setTimeout> | null = null
  let warnTimerId: ReturnType<typeof setTimeout> | null = null

  const handle = opts.client.listen()

  if (devWarnMs > 0 && !isProductionEnv()) {
    warnTimerId = setTimeout(() => {
      if (!firstEventReceived && !disposed) {
        console.warn(
          `@barkpark/nextjs <BarkparkLive /> received no SSE event in ${devWarnMs}ms — verify Phoenix /v1/data/listen, dataset, and CORS.`,
        )
      }
    }, devWarnMs)
  }

  const teardown = (): void => {
    if (disposed) return
    disposed = true
    if (timerId !== null) {
      clearTimeout(timerId)
      timerId = null
    }
    if (warnTimerId !== null) {
      clearTimeout(warnTimerId)
      warnTimerId = null
    }
    if (typeof window !== 'undefined' && typeof window.removeEventListener === 'function') {
      window.removeEventListener('beforeunload', onBeforeUnload)
    }
    handle.unsubscribe()
  }

  const onBeforeUnload = (): void => {
    teardown()
  }

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('beforeunload', onBeforeUnload)
  }

  const hot = getHotApi()
  if (hot?.dispose !== undefined) {
    hot.dispose(teardown)
  }

  ;(async () => {
    try {
      for await (const _evt of handle) {
        if (disposed) return
        firstEventReceived = true
        if (timerId !== null) clearTimeout(timerId)
        timerId = setTimeout(() => {
          timerId = null
          if (!disposed) opts.refresh()
        }, debounceMs)
      }
    } catch (e) {
      if (!disposed && !isProductionEnv()) {
        console.warn('@barkpark/nextjs <BarkparkLive /> SSE subscription terminated:', e)
      }
    }
  })()

  return teardown
}
