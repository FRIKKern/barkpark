import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

// next/navigation: useRouter is mocked so render-time component code can resolve it
const { routerRefreshMock } = vi.hoisted(() => ({
  routerRefreshMock: vi.fn(),
}))
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
import {
  BarkparkLive,
  BarkparkLiveProvider,
  detectEdgeRuntime,
  startLiveSubscription,
  type StartLiveOpts,
} from '../src/client/live'
import { BarkparkEdgeRuntimeError, type BarkparkClient, type ListenEvent } from '@barkpark/core'

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

interface ControllableHandle<T = ListenEvent> extends AsyncIterable<T> {
  push(evt: T): void
  end(): void
  unsubscribe: ReturnType<typeof vi.fn>
}

function makeFakeListenHandle(): ControllableHandle {
  const queue: ListenEvent[] = []
  let resolveNext: ((evt: IteratorResult<ListenEvent>) => void) | null = null
  let ended = false

  return {
    [Symbol.asyncIterator](): AsyncIterator<ListenEvent> {
      return {
        next(): Promise<IteratorResult<ListenEvent>> {
          if (queue.length > 0) {
            const value = queue.shift()!
            return Promise.resolve({ value, done: false })
          }
          if (ended) return Promise.resolve({ value: undefined as unknown as ListenEvent, done: true })
          return new Promise((res) => {
            resolveNext = res
          })
        },
      }
    },
    push(evt) {
      if (resolveNext !== null) {
        const r = resolveNext
        resolveNext = null
        r({ value: evt, done: false })
      } else {
        queue.push(evt)
      }
    },
    end() {
      ended = true
      if (resolveNext !== null) {
        const r = resolveNext
        resolveNext = null
        r({ value: undefined as unknown as ListenEvent, done: true })
      }
    },
    unsubscribe: vi.fn(),
  }
}

function makeFakeClient(handle: ControllableHandle): BarkparkClient {
  return {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-01-01',
    },
    listen: vi.fn(() => handle),
  } as unknown as BarkparkClient
}

let container: HTMLDivElement | null = null
let root: Root | null = null

function mount(node: React.ReactNode): void {
  container = document.createElement('div')
  document.body.appendChild(container)
  root = createRoot(container)
  act(() => {
    root!.render(node)
  })
}

function unmount(): void {
  if (root !== null) {
    act(() => {
      root!.unmount()
    })
    root = null
  }
  if (container !== null) {
    container.remove()
    container = null
  }
}

beforeEach(() => {
  routerRefreshMock.mockReset()
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
})

afterEach(() => {
  unmount()
  vi.useRealTimers()
  // restore any global mutations
  delete (globalThis as { EdgeRuntime?: unknown }).EdgeRuntime
})

// ---------------------------------------------------------------------------
// detectEdgeRuntime / assertNotEdge
// ---------------------------------------------------------------------------

describe('detectEdgeRuntime — three-layer detector', () => {
  it('returns null in a normal node/jsdom environment', () => {
    expect(detectEdgeRuntime()).toBeNull()
  })

  it('layer 1: trips on globalThis.EdgeRuntime', () => {
    ;(globalThis as { EdgeRuntime?: string }).EdgeRuntime = 'edge-light'
    expect(detectEdgeRuntime()).toBe('globalThis.EdgeRuntime')
  })

  it('layer 2: trips on process.env.NEXT_RUNTIME==="edge"', () => {
    const prev = process.env.NEXT_RUNTIME
    process.env.NEXT_RUNTIME = 'edge'
    try {
      expect(detectEdgeRuntime()).toBe('process.env.NEXT_RUNTIME==="edge"')
    } finally {
      if (prev === undefined) delete process.env.NEXT_RUNTIME
      else process.env.NEXT_RUNTIME = prev
    }
  })
  // Layer 3 (no `process` global) is hard to simulate inside jsdom without breaking other tests;
  // covered structurally by the source-level if-branch and the synchronous render-time check.
})

// ---------------------------------------------------------------------------
// startLiveSubscription — pure helper
// ---------------------------------------------------------------------------

describe('startLiveSubscription', () => {
  it('throws BarkparkEdgeRuntimeError when edge runtime is detected', () => {
    ;(globalThis as { EdgeRuntime?: string }).EdgeRuntime = 'workerd'
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    expect(() =>
      startLiveSubscription({ client, refresh: () => {}, debounceMs: 0, devWarnMs: 0 }),
    ).toThrow(BarkparkEdgeRuntimeError)
  })

  it('debounces refresh by 500ms and coalesces bursts into one call', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    const refresh = vi.fn()
    const opts: StartLiveOpts = { client, refresh, debounceMs: 500, devWarnMs: 0 }
    const teardown = startLiveSubscription(opts)

    // Send three events in rapid succession
    handle.push({ eventId: '1', type: 'mutation' })
    handle.push({ eventId: '2', type: 'mutation' })
    handle.push({ eventId: '3', type: 'mutation' })
    // Let the async iterator drain
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
      await Promise.resolve()
    })

    // Before the debounce window elapses no refresh has fired
    vi.advanceTimersByTime(499)
    expect(refresh).not.toHaveBeenCalled()

    // After 500ms the (single) coalesced refresh fires
    vi.advanceTimersByTime(2)
    expect(refresh).toHaveBeenCalledTimes(1)

    teardown()
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })

  it('teardown clears the pending debounce timer (no late refresh)', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    const refresh = vi.fn()
    const teardown = startLiveSubscription({ client, refresh, debounceMs: 500, devWarnMs: 0 })

    handle.push({ eventId: '1', type: 'mutation' })
    await act(async () => {
      await Promise.resolve()
    })
    vi.advanceTimersByTime(100)
    teardown()
    vi.advanceTimersByTime(1000)

    expect(refresh).not.toHaveBeenCalled()
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })

  it('dev-mode 5s no-event warning fires when no events arrive', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const teardown = startLiveSubscription({
      client,
      refresh: () => {},
      debounceMs: 0,
      devWarnMs: 5000,
    })

    vi.advanceTimersByTime(5001)
    expect(warnSpy).toHaveBeenCalledOnce()
    expect(warnSpy.mock.calls[0]![0]).toMatch(/no SSE event in 5000ms/)

    teardown()
    warnSpy.mockRestore()
  })

  it('dev warning does NOT fire if an event arrives before the deadline', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const teardown = startLiveSubscription({
      client,
      refresh: () => {},
      debounceMs: 0,
      devWarnMs: 5000,
    })

    handle.push({ eventId: '1', type: 'mutation' })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })
    vi.advanceTimersByTime(6000)

    expect(warnSpy).not.toHaveBeenCalled()
    teardown()
    warnSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// <BarkparkLive /> + <BarkparkLiveProvider />
// ---------------------------------------------------------------------------

describe('<BarkparkLive />', () => {
  it('throws synchronously in render when edge runtime is detected', () => {
    ;(globalThis as { EdgeRuntime?: string }).EdgeRuntime = 'edge-light'
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    expect(() => mount(<BarkparkLive client={client} devWarnMs={0} />)).toThrow(BarkparkEdgeRuntimeError)
  })

  it('mount → subscribe / event → debounced router.refresh() / unmount → unsubscribe', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)

    mount(<BarkparkLive client={client} debounceMs={500} devWarnMs={0} />)
    expect(client.listen).toHaveBeenCalledOnce()

    // Push a mutation event
    handle.push({ eventId: '1', type: 'mutation' })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })

    // Debounce window not yet elapsed
    expect(routerRefreshMock).not.toHaveBeenCalled()
    vi.advanceTimersByTime(500)
    expect(routerRefreshMock).toHaveBeenCalledOnce()

    // Unmount: subscription tears down (HMR-safe)
    unmount()
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })
})

describe('<BarkparkLiveProvider />', () => {
  it('mounts a single BarkparkLive bound to the supplied client', async () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)

    mount(
      <BarkparkLiveProvider client={client} debounceMs={500} devWarnMs={0}>
        <span>app</span>
      </BarkparkLiveProvider>,
    )

    expect(client.listen).toHaveBeenCalledOnce()
    expect(container?.textContent).toBe('app')

    handle.push({ eventId: '1', type: 'mutation' })
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })
    vi.advanceTimersByTime(500)
    expect(routerRefreshMock).toHaveBeenCalledOnce()

    unmount()
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })
})

// ---------------------------------------------------------------------------
// beforeunload teardown
// ---------------------------------------------------------------------------

describe('beforeunload teardown', () => {
  it('fires teardown when window dispatches beforeunload', () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    startLiveSubscription({ client, refresh: () => {}, debounceMs: 0, devWarnMs: 0 })

    expect(handle.unsubscribe).not.toHaveBeenCalled()
    window.dispatchEvent(new Event('beforeunload'))
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })

  it('manual teardown removes the beforeunload listener (idempotent)', () => {
    const handle = makeFakeListenHandle()
    const client = makeFakeClient(handle)
    const teardown = startLiveSubscription({ client, refresh: () => {}, debounceMs: 0, devWarnMs: 0 })

    teardown()
    // Dispatching beforeunload after manual teardown must NOT call unsubscribe again
    window.dispatchEvent(new Event('beforeunload'))
    expect(handle.unsubscribe).toHaveBeenCalledOnce()
  })
})

// ---------------------------------------------------------------------------
// HMR dispose teardown
// ---------------------------------------------------------------------------

describe('HMR dispose teardown', () => {
  it('registers teardown via globalThis.module.hot.dispose when present', () => {
    const hotDispose = vi.fn<(cb: () => void) => void>()
    ;(globalThis as unknown as { module: { hot: { dispose: typeof hotDispose } } }).module = {
      hot: { dispose: hotDispose },
    }
    try {
      const handle = makeFakeListenHandle()
      const client = makeFakeClient(handle)
      startLiveSubscription({ client, refresh: () => {}, debounceMs: 0, devWarnMs: 0 })

      expect(hotDispose).toHaveBeenCalledOnce()
      // Simulate the HMR runtime firing the dispose callback
      const cb = hotDispose.mock.calls[0]![0]
      cb()
      expect(handle.unsubscribe).toHaveBeenCalledOnce()
    } finally {
      delete (globalThis as { module?: unknown }).module
    }
  })
})
