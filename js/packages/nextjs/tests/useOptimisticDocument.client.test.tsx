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

interface TestDoc {
  _id: string
  _type: string
  _rev?: string
  title: string
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
