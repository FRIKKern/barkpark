// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect, vi } from 'vitest'
import { act, render, waitFor } from '@testing-library/react'
import type { ReactElement } from 'react'
import { BarkparkReference } from '../src/Reference'
import type {
  ResolvedDoc,
  BarkparkReferenceClient,
} from '../src/Reference'

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

  // The API's ONLY doc route is the 3-segment /v1/data/doc/:dataset/:type/:id.
  // These stubs 404 anything off that route, so a wrong (typeless) path can't
  // masquerade as a hit — a regression to the old 2-segment path fails loudly.
  const THREE_SEG = /\/v1\/data\/doc\/[^/]+\/[^/]+\/[^/]+$/

  it('builds the real 3-segment doc path for a typed reference (scope-aware)', async () => {
    const paths: string[] = []
    const client: BarkparkReferenceClient = {
      // No `doc` getter → falls through to fetchRaw + buildDocPath.
      fetchRaw: async <T = Response>(path: string): Promise<T> => {
        paths.push(path)
        if (!THREE_SEG.test(path)) return new Response('', { status: 404 }) as T
        return new Response(
          JSON.stringify({ result: { _id: 'scoped-1', _type: 'post', title: 'Scoped' } }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ) as T
      },
      config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'scoped-1', _type: 'post' }} client={client}>
        {renderDoc}
      </BarkparkReference>,
    )
    await findByTestId('doc-scoped-1')
    // Scoped: /w/:ws/p/:proj prefix + dataset + type + id — the canonical route.
    expect(paths[0]).toBe('/w/acme/p/blog/v1/data/doc/staging/post/scoped-1')
    expect(paths.every((p) => !p.includes('production'))).toBe(true)
  })

  it('honors an explicit `type` prop when the reference value carries none', async () => {
    const paths: string[] = []
    const client: BarkparkReferenceClient = {
      fetchRaw: async <T = Response>(path: string): Promise<T> => {
        paths.push(path)
        if (!THREE_SEG.test(path)) return new Response('', { status: 404 }) as T
        return new Response(
          JSON.stringify({ result: { _id: 'flat-1', _type: 'author', title: 'Typed' } }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        ) as T
      },
      config: { dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'flat-1' }} type="author" client={client}>
        {renderDoc}
      </BarkparkReference>,
    )
    await findByTestId('doc-flat-1')
    // Unscoped config → no /w/p prefix, but type is now in the path.
    expect(paths[0]).toBe('/v1/data/doc/staging/author/flat-1')
  })

  it('resolves a typed reference through the client `doc(type, id)` getter', async () => {
    const calls: Array<[string, string]> = []
    const client: BarkparkReferenceClient = {
      // Real core client exposes both; `doc` is preferred when a type is known.
      doc: async <T = ResolvedDoc>(type: string, id: string): Promise<T | null> => {
        calls.push([type, id])
        return { _id: id, _type: type, title: 'Via doc' } as T
      },
      fetchRaw: async <T = Response>(): Promise<T> => {
        throw new Error('doc() should have been used, not fetchRaw')
      },
      config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'author-1', _type: 'author' }} client={client}>
        {renderDoc}
      </BarkparkReference>,
    )
    expect((await findByTestId('doc-author-1')).textContent).toBe('Via doc')
    // Suspense may retry the render, so doc() can fire more than once — assert
    // it was called and always with the (type, id) pair, not an exact count.
    expect(calls.length).toBeGreaterThan(0)
    expect(calls.every(([t, i]) => t === 'author' && i === 'author-1')).toBe(true)
  })

  it('falls back to notFound for an untyped reference (legacy 2-segment route 404s)', async () => {
    const paths: string[] = []
    const client: BarkparkReferenceClient = {
      // Only the 3-segment route is served; the typeless path 404s → notFound.
      fetchRaw: async <T = Response>(path: string): Promise<T> => {
        paths.push(path)
        return new Response('', { status: THREE_SEG.test(path) ? 200 : 404 }) as T
      },
      config: { dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'untyped-1' }}
        client={client}
        notFound={<div data-testid="nf-untyped">missing</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    // Current behavior preserved: no throw, graceful notFound.
    expect((await findByTestId('nf-untyped')).textContent).toBe('missing')
    expect(paths[0]).toBe('/v1/data/doc/staging/untyped-1')
  })

  it('unwraps the /v1/data/doc envelope from a real-client Response', async () => {
    const doc = { _id: 'r1', _type: 'author', name: 'Ada', title: 'Ada' }
    const client: BarkparkReferenceClient = {
      fetchRaw: async <T = Response>(): Promise<T> =>
        new Response(JSON.stringify({ result: doc }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }) as T,
      config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference ref={{ _ref: 'r1' }} client={client}>
        {(author) => (
          <div data-testid={`author-${author._id}`}>{author.name as string}</div>
        )}
      </BarkparkReference>,
    )
    expect((await findByTestId('author-r1')).textContent).toBe('Ada')
  })

  it('renders notFound when the real-client Response is non-ok', async () => {
    const client: BarkparkReferenceClient = {
      fetchRaw: async <T = Response>(): Promise<T> =>
        new Response('', { status: 404 }) as T,
      config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
    }
    const { findByTestId } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'gone' }}
        client={client}
        notFound={<div data-testid="nf-raw">missing</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect((await findByTestId('nf-raw')).textContent).toBe('missing')
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
