// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect, vi } from 'vitest'
import { act, render } from '@testing-library/react'
import { Component, type ReactElement, type ReactNode } from 'react'
import { BarkparkConflictError } from '@barkpark/core'
import {
  useOptimisticDocument,
  type UseOptimisticDocumentResult,
} from '../src/actions/useOptimisticDocument'
// Protective export-completeness: these MUST be importable from the actions ENTRY
// (../src/actions/index), not just the internal file — they type the exported
// useOptimisticDocument hook's return + conflict. Un-export from index → tsc fails.
import type {
  OptimisticDocumentConflict as _EntryConflict,
  UseOptimisticDocumentResult as _EntryResult,
} from '../src/actions/index'

const _conflictFromEntry: _EntryConflict = {}
const _resultFromEntry: _EntryResult<{ _id: string; _type: string }> | null = null
void _conflictFromEntry
void _resultFromEntry

interface TestDoc {
  _id: string
  _type: string
  _rev?: string
  title: string
  body?: string
}

type Capture<T> = { current: UseOptimisticDocumentResult<T> | null }

function HookHarness(props: {
  initial: TestDoc
  action: (doc: TestDoc) => Promise<TestDoc>
  capture: Capture<TestDoc>
}): ReactElement {
  const state = useOptimisticDocument(props.initial, props.action)
  props.capture.current = state
  return <div data-testid="doc">{state.data.title}</div>
}

class ErrorBoundary extends Component<
  { children: ReactNode; onError?: (e: unknown) => void },
  { err: unknown }
> {
  override state: { err: unknown } = { err: null }
  static getDerivedStateFromError(err: unknown): { err: unknown } {
    return { err }
  }
  override componentDidCatch(err: unknown): void {
    this.props.onError?.(err)
  }
  override render(): ReactNode {
    if (this.state.err !== null) return <div data-testid="err">caught</div>
    return this.props.children
  }
}

function renderHook(
  initial: TestDoc,
  action: (doc: TestDoc) => Promise<TestDoc>,
  opts?: { onError?: (e: unknown) => void },
): Capture<TestDoc> {
  const capture: Capture<TestDoc> = { current: null }
  const boundaryProps: { children: ReactNode; onError?: (e: unknown) => void } = {
    children: <HookHarness initial={initial} action={action} capture={capture} />,
  }
  if (opts?.onError !== undefined) boundaryProps.onError = opts.onError
  render(<ErrorBoundary {...boundaryProps} />)
  return capture
}

const baseDoc: TestDoc = { _id: 'p1', _type: 'post', title: 'initial' }

describe('useOptimisticDocument', () => {
  it('initial render exposes initialDoc, pending=false, no conflict', () => {
    const capture = renderHook(baseDoc, async (d) => d)
    expect(capture.current?.data).toEqual(baseDoc)
    expect(capture.current?.pending).toBe(false)
    expect(capture.current?.conflict).toBeUndefined()
  })

  it('optimistic path: applies patch, then settles to server result', async () => {
    const serverDoc: TestDoc = { ...baseDoc, title: 'server-accepted' }
    const action = vi.fn(async (_optimistic: TestDoc) => serverDoc)
    const capture = renderHook(baseDoc, action)

    await act(async () => {
      capture.current?.mutate({ title: 'new' })
    })

    expect(action).toHaveBeenCalledTimes(1)
    expect(capture.current?.data.title).toBe('server-accepted')
    expect(capture.current?.pending).toBe(false)
    expect(capture.current?.conflict).toBeUndefined()
  })

  it('rapid successive mutations accumulate: the second server payload carries the first in-flight patch', async () => {
    // Record each payload the server action receives, and hand back a promise we
    // resolve by hand so the second mutate fires while the first is still in flight.
    const payloads: TestDoc[] = []
    const resolvers: Array<(doc: TestDoc) => void> = []
    const action = vi.fn(
      (doc: TestDoc): Promise<TestDoc> =>
        new Promise<TestDoc>((resolve) => {
          payloads.push(doc)
          resolvers.push(resolve)
        }),
    )
    const capture = renderHook(baseDoc, action)

    await act(async () => {
      capture.current?.mutate({ title: 'x' })
    })
    await act(async () => {
      capture.current?.mutate({ body: 'y' })
    })

    expect(payloads).toHaveLength(2)
    // Pre-fix this fails: the second payload is built from stale `committed` and
    // omits title:'x', silently dropping the first in-flight patch server-side.
    expect(payloads[1]).toMatchObject({ title: 'x', body: 'y' })

    // Resolve both round-trips (oldest first) and assert the committed view merges.
    await act(async () => {
      resolvers[0]?.({ ...baseDoc, title: 'x' })
      resolvers[1]?.({ ...baseDoc, title: 'x', body: 'y' })
    })

    expect(capture.current?.data).toMatchObject({ title: 'x', body: 'y' })
    expect(capture.current?.pending).toBe(false)
    expect(capture.current?.conflict).toBeUndefined()
  })

  it('conflict path: BarkparkConflictError populates conflict, rolls back data, clears pending', async () => {
    const action = vi.fn(async (_optimistic: TestDoc): Promise<TestDoc> => {
      throw new BarkparkConflictError('ifMatch mismatch', {
        status: 409,
        serverEtag: 'abc',
        serverDoc: { title: 'server' },
      })
    })
    const capture = renderHook(baseDoc, action)

    await act(async () => {
      capture.current?.mutate({ title: 'stale-client' })
    })

    expect(capture.current?.conflict).toEqual({
      serverEtag: 'abc',
      serverDoc: { title: 'server' },
    })
    expect(capture.current?.data).toEqual(baseDoc)
    expect(capture.current?.pending).toBe(false)
  })

  it('conflict path: code-string fallback is honored when instanceof fails', async () => {
    // Simulate a duplicate-bundle scenario where `instanceof` is false but
    // `code === 'BarkparkConflictError'` still identifies the error class.
    const forgedConflict = Object.assign(new Error('duplicate-bundle'), {
      code: 'BarkparkConflictError',
      serverEtag: 'xyz',
      serverDoc: { title: 'dup' },
    })
    const action = vi.fn(async (_optimistic: TestDoc): Promise<TestDoc> => {
      throw forgedConflict
    })
    const capture = renderHook(baseDoc, action)

    await act(async () => {
      capture.current?.mutate({ title: 'client' })
    })

    expect(capture.current?.conflict).toEqual({
      serverEtag: 'xyz',
      serverDoc: { title: 'dup' },
    })
  })

  it('clearConflict dismisses a populated conflict', async () => {
    const action = vi.fn(async (): Promise<TestDoc> => {
      throw new BarkparkConflictError('conflict', { serverEtag: 'abc' })
    })
    const capture = renderHook(baseDoc, action)

    await act(async () => {
      capture.current?.mutate({ title: 'x' })
    })
    expect(capture.current?.conflict).toBeDefined()

    await act(async () => {
      capture.current?.clearConflict()
    })
    expect(capture.current?.conflict).toBeUndefined()
  })

  it('non-conflict errors propagate to ErrorBoundary, conflict stays undefined', async () => {
    const action = vi.fn(async (): Promise<TestDoc> => {
      throw new Error('network boom')
    })
    const onError = vi.fn()
    // Suppress React's noisy console.error for the intentional uncaught throw.
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const capture = renderHook(baseDoc, action, { onError })

    await act(async () => {
      capture.current?.mutate({ title: 'wont-stick' })
    })

    expect(onError).toHaveBeenCalled()
    const caught = onError.mock.calls[0]?.[0]
    expect(caught).toBeInstanceOf(Error)
    expect((caught as Error).message).toBe('network boom')
    // conflict was never set because the error is not a BarkparkConflictError.
    // capture.current may still point at last-rendered state (before the throw).
    expect(capture.current?.conflict).toBeUndefined()

    consoleSpy.mockRestore()
  })
})
