// Runs under a REAL headless chromium (see vitest.browser.config.ts), not jsdom.
//
// Why a separate project: the `client` project is jsdom-under-node, where
// `process` always exists. The single most common runtime for
// `@barkpark/nextjs/client` — a browser with no bundler-injected `process`
// shim — could therefore never be reached by a test, and the detector's
// browser behaviour went unexercised until it broke.
import { describe, it, expect, vi, afterEach } from 'vitest'

const { routerRefreshMock } = vi.hoisted(() => ({ routerRefreshMock: vi.fn() }))
vi.mock('next/navigation', () => ({
  useRouter: () => ({
    refresh: routerRefreshMock,
    push: vi.fn(),
    replace: vi.fn(),
    back: vi.fn(),
    forward: vi.fn(),
    prefetch: vi.fn(),
  }),
}))

import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { BarkparkLive, detectEdgeRuntime, startLiveSubscription } from '../src/client/live'
import type { BarkparkClient, ListenEvent } from '@barkpark/core'

type Mutable = Record<string, unknown>
const g = globalThis as unknown as Mutable

// React 19 requires this flag before act() will drive updates outside a
// framework test harness. Without it React logs "The current testing
// environment is not configured to support act(...)".
g.IS_REACT_ACT_ENVIRONMENT = true

afterEach(() => {
  delete g.EdgeRuntime
  delete g.WebSocketPair
})

function makeIdleClient(): { client: BarkparkClient; listen: ReturnType<typeof vi.fn> } {
  const unsubscribe = vi.fn()
  const handle = {
    [Symbol.asyncIterator](): AsyncIterator<ListenEvent> {
      return { next: () => new Promise<IteratorResult<ListenEvent>>(() => {}) }
    },
    unsubscribe,
  }
  const listen = vi.fn(() => handle)
  return {
    client: {
      config: {
        projectUrl: 'http://localhost:4000',
        dataset: 'production',
        apiVersion: '2026-01-01',
      },
      listen,
    } as unknown as BarkparkClient,
    listen,
  }
}

// ---------------------------------------------------------------------------
// Instrument check — prove the realm is the one the assertions claim.
// Without this the suite could pass in a runtime that quietly has `process`,
// which is exactly how the jsdom project produced a false sense of coverage.
// ---------------------------------------------------------------------------
describe('browser realm preconditions', () => {
  it('is a real browser: window + ReadableStream present, `process` absent', () => {
    expect(typeof window).toBe('object')
    expect(navigator.userAgent).toMatch(/Chrome|Chromium|HeadlessChrome/)
    expect(typeof ReadableStream).toBe('function')
    // The precondition that makes the next test meaningful. If a bundler or the
    // test runner ever injects a `process` shim here, THIS assertion fails and
    // says so, instead of the suite silently going vacuous.
    expect(typeof process).toBe('undefined')
  })
})

// ---------------------------------------------------------------------------
// The defect: a plain browser must not be classified as an edge runtime.
// RED on the pre-fix detector (layer 3 returned 'globalThis.ReadableStream && !process').
// ---------------------------------------------------------------------------
describe('detectEdgeRuntime in a browser', () => {
  it('returns null — a browser is NOT an edge runtime', () => {
    expect(detectEdgeRuntime()).toBeNull()
  })

  // ABSENCE proved above is only half the contract. These prove the guard is
  // still a guard: a fix that hard-coded `return null` would fail here.
  it('still detects the Vercel edge runtime (globalThis.EdgeRuntime)', () => {
    g.EdgeRuntime = 'edge-light'
    expect(detectEdgeRuntime()).not.toBeNull()
  })

  it('still detects workerd / Cloudflare Workers (globalThis.WebSocketPair)', () => {
    g.WebSocketPair = class {}
    expect(detectEdgeRuntime()).not.toBeNull()
  })
})

// ---------------------------------------------------------------------------
// Trace the interception, not the definition: the detector only matters because
// two call sites throw on it. Prove BOTH stop firing in a browser.
// ---------------------------------------------------------------------------
describe('<BarkparkLive /> in a browser', () => {
  let root: Root | null = null
  let container: HTMLDivElement | null = null

  afterEach(() => {
    if (root !== null) {
      act(() => root!.unmount())
      root = null
    }
    container?.remove()
    container = null
  })

  it('renders and subscribes instead of throwing BarkparkEdgeRuntimeError', () => {
    const { client, listen } = makeIdleClient()
    container = document.createElement('div')
    document.body.appendChild(container)
    root = createRoot(container)

    // live.tsx:72 — assertNotEdge() runs synchronously during render.
    act(() => {
      root!.render(<BarkparkLive client={client} devWarnMs={0} />)
    })

    // live.tsx:180 — assertNotEdge() runs again inside startLiveSubscription,
    // reached via the mount effect. If either threw, listen() never ran.
    expect(listen).toHaveBeenCalledTimes(1)
  })

  it('startLiveSubscription subscribes directly (non-React call site)', () => {
    const { client, listen } = makeIdleClient()
    const teardown = startLiveSubscription({
      client,
      refresh: () => {},
      debounceMs: 0,
      devWarnMs: 0,
    })
    expect(listen).toHaveBeenCalledTimes(1)
    teardown()
  })
})
