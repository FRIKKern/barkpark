// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect, vi } from 'vitest'
import { act, render, waitFor } from '@testing-library/react'
import type { ReactElement } from 'react'
import { BarkparkReference } from '../src/Reference'
import type { ResolvedDoc } from '../src/Reference'

function renderDoc(doc: ResolvedDoc): ReactElement {
  return <div data-testid={`doc-${doc._id}`}>{String(doc.title ?? '')}</div>
}

async function renderAsync(
  node: ReactElement,
): Promise<ReturnType<typeof render>> {
  let result!: ReturnType<typeof render>
  await act(async () => {
    result = render(node)
  })
  return result
}

describe('BarkparkReference', () => {
  it('renders fetched doc via fetcher', async () => {
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      title: 'Hello',
    }))
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'p1' }} fetcher={fetcher}>
        {renderDoc}
      </BarkparkReference>,
    )
    const el = await findByTestId('doc-p1')
    expect(el.textContent).toBe('Hello')
    expect(fetcher).toHaveBeenCalledWith('p1')
  })

  it('short-circuits when ref is already a resolved doc', async () => {
    const fetcher = vi.fn()
    const { getByTestId } = await renderAsync(
      <BarkparkReference
        ref={{ _id: 'p9', _type: 'post', title: 'Inline' }}
        fetcher={fetcher as never}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(getByTestId('doc-p9').textContent).toBe('Inline')
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('renders notFound when fetcher returns null', async () => {
    const fetcher = vi.fn(async () => null)
    const { findByTestId } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'missing' }}
        fetcher={fetcher}
        notFound={<div data-testid="nf">not found</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect((await findByTestId('nf')).textContent).toBe('not found')
  })

  it('renders fallback while the promise is pending', async () => {
    const pending = new Promise<ResolvedDoc | null>(() => {
      /* never resolves within the test */
    })
    const fetcher = (): Promise<ResolvedDoc | null> => pending
    const result = render(
      <BarkparkReference
        ref={{ _ref: 'slow' }}
        fetcher={fetcher}
        fallback={<div data-testid="fb">loading…</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(result.getByTestId('fb').textContent).toBe('loading…')
  })

  it('detects cycles and invokes onCycle', async () => {
    const onCycle = vi.fn()
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      title: `T-${id}`,
    }))
    const { findByTestId, queryByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'p1' }} fetcher={fetcher} onCycle={onCycle}>
        {(outer) => (
          <div data-testid={`outer-${outer._id}`}>
            {outer.title as string}
            <BarkparkReference
              ref={{ _ref: 'p1' }}
              fetcher={fetcher}
              onCycle={onCycle}
            >
              {(inner) => (
                <div data-testid={`inner-${inner._id}`}>{inner.title as string}</div>
              )}
            </BarkparkReference>
          </div>
        )}
      </BarkparkReference>,
    )
    await findByTestId('outer-p1')
    await waitFor(() => expect(onCycle).toHaveBeenCalled())
    expect(onCycle).toHaveBeenCalledWith('p1')
    expect(queryByTestId('inner-p1')).toBeNull()
  })

  it('enforces default maxDepth = 5 and calls onMaxDepth at level 6', async () => {
    const onMaxDepth = vi.fn()
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      next: `p${Number(id.slice(1)) + 1}`,
    }))
    function RefAt(props: { id: string }): ReactElement {
      return (
        <BarkparkReference
          ref={{ _ref: props.id }}
          fetcher={fetcher}
          onMaxDepth={onMaxDepth}
        >
          {(doc) => (
            <div data-testid={`lvl-${doc._id}`}>
              <RefAt id={doc.next as string} />
            </div>
          )}
        </BarkparkReference>
      )
    }
    const { findByTestId } = await renderAsync(<RefAt id="p0" />)
    // Levels 0..4 should render fine (5 levels); level 5 (id p5) is blocked.
    await findByTestId('lvl-p4')
    await waitFor(() => expect(onMaxDepth).toHaveBeenCalled())
    expect(onMaxDepth).toHaveBeenCalledWith('p5', 5)
  })

  it('respects custom maxDepth=2', async () => {
    const onMaxDepth = vi.fn()
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      next: `p${Number(id.slice(1)) + 1}`,
    }))
    function RefAt(props: { id: string }): ReactElement {
      return (
        <BarkparkReference
          ref={{ _ref: props.id }}
          fetcher={fetcher}
          maxDepth={2}
          onMaxDepth={onMaxDepth}
        >
          {(doc) => (
            <div data-testid={`c-${doc._id}`}>
              <RefAt id={doc.next as string} />
            </div>
          )}
        </BarkparkReference>
      )
    }
    const { findByTestId } = await renderAsync(<RefAt id="p0" />)
    await findByTestId('c-p1')
    await waitFor(() => expect(onMaxDepth).toHaveBeenCalled())
    expect(onMaxDepth).toHaveBeenCalledWith('p2', 2)
  })

  it('accepts a string ref and passes it to fetcher', async () => {
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      title: 'raw-' + id,
    }))
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref="post-abc" fetcher={fetcher}>
        {renderDoc}
      </BarkparkReference>,
    )
    expect((await findByTestId('doc-post-abc')).textContent).toBe('raw-post-abc')
    expect(fetcher).toHaveBeenCalledWith('post-abc')
  })

  it('renders sibling refs to the same id without firing onCycle', async () => {
    const onCycle = vi.fn()
    const fetcher = vi.fn(async (id: string): Promise<ResolvedDoc> => ({
      _id: id,
      _type: 'post',
      title: 'Sibling',
    }))
    const { findAllByTestId } = await renderAsync(
      <div>
        <BarkparkReference ref={{ _ref: 'sib' }} fetcher={fetcher} onCycle={onCycle}>
          {renderDoc}
        </BarkparkReference>
        <BarkparkReference ref={{ _ref: 'sib' }} fetcher={fetcher} onCycle={onCycle}>
          {renderDoc}
        </BarkparkReference>
      </div>,
    )
    const els = await findAllByTestId('doc-sib')
    expect(els).toHaveLength(2)
    expect(onCycle).not.toHaveBeenCalled()
  })
})
