// @vitest-environment happy-dom
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// The non-2xx discrimination harness. Before this file's fix, every one of
// 401/403/429/500/502/503 rendered the SAME empty output as a genuine 404, on
// BOTH derived-fetcher branches (`client.doc(type, id)` and `client.fetchRaw`).
// The pre-fix run of this file passed 15/15 asserting exactly that collapse.
//
// It now asserts the opposite, and the two branches are checked SEPARATELY —
// the repair is asymmetric (core's `code` taxonomy on one, a typed status error
// on the other), so a single shared assertion would cover only half of it.
// The 404 arm and the 200 control are pinned unchanged: a repair that also
// moved the miss behaviour would be a different change.

import { describe, it, expect, vi } from 'vitest'
import { act, render } from '@testing-library/react'
import type { ReactElement } from 'react'
import {
  BarkparkAPIError,
  BarkparkAuthError,
  BarkparkNotFoundError,
  BarkparkRateLimitError,
} from '@barkpark/core'
import { BarkparkReference } from '../src/Reference'
import type {
  BarkparkReferenceFetchError,
  ResolvedDoc,
  BarkparkReferenceClient,
} from '../src/Reference'

const NON_OK = [401, 403, 429, 500, 502, 503] as const

function renderDoc(doc: ResolvedDoc): ReactElement {
  return <div data-testid={`doc-${doc._id}`}>{String(doc.title ?? '')}</div>
}

async function renderAsync(node: ReactElement): Promise<ReturnType<typeof render>> {
  let result!: ReturnType<typeof render>
  await act(async () => {
    result = render(node)
  })
  return result
}

/** Client whose `fetchRaw` answers with a bare Response of the given status. */
function rawClient(status: number): BarkparkReferenceClient {
  return {
    fetchRaw: async <T = Response>(): Promise<T> =>
      (status === 200
        ? new Response(
            JSON.stringify({ result: { _id: 'x', _type: 'post', title: 'Live' } }),
            { status: 200, headers: { 'content-type': 'application/json' } },
          )
        : new Response('', { status })) as T,
    config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
  }
}

/** Client whose `doc()` behaves like the real core client at the given status. */
function docClient(status: number): BarkparkReferenceClient {
  return {
    doc: async <T = ResolvedDoc>(type: string, id: string): Promise<T | null> => {
      if (status === 200) return { _id: id, _type: type, title: 'Live' } as T
      // Real core `doc()` swallows 404 into null; every other status throws its
      // taxonomy class, each carrying a `code` equal to the class name.
      if (status === 404) return null
      if (status === 401 || status === 403) throw new BarkparkAuthError('denied', { status })
      if (status === 429) throw new BarkparkRateLimitError('slow down', { status })
      throw new BarkparkAPIError('boom', { status })
    },
    config: { workspace: 'acme', project: 'blog', dataset: 'staging' },
  }
}

describe('BarkparkReference — a failed fetch is not a missing document', () => {
  it('CONTROL: a 200 still renders on both branches', async () => {
    const raw = await renderAsync(
      <BarkparkReference ref={{ _ref: 'x', _type: 'post' }} client={rawClient(200)}>
        {renderDoc}
      </BarkparkReference>,
    )
    expect(raw.container.innerHTML).toContain('Live')

    const viaDoc = await renderAsync(
      <BarkparkReference ref={{ _ref: 'x', _type: 'post' }} client={docClient(200)}>
        {renderDoc}
      </BarkparkReference>,
    )
    expect(viaDoc.container.innerHTML).toContain('Live')
  })

  it('UNCHANGED: a genuine 404 still renders `notFound`, not the error path (fetchRaw branch)', async () => {
    const onError = vi.fn()
    const { container } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'x', _type: 'post' }}
        client={rawClient(404)}
        notFound={<div data-testid="nf">missing</div>}
        errorFallback={<div data-testid="ef">failed</div>}
        onError={onError}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(container.innerHTML).toContain('missing')
    expect(container.innerHTML).not.toContain('failed')
    expect(onError).not.toHaveBeenCalled()
  })

  it('UNCHANGED: a BarkparkNotFoundError from doc() is still a miss, not an error', async () => {
    const onError = vi.fn()
    const client: BarkparkReferenceClient = {
      doc: async () => {
        throw new BarkparkNotFoundError('no such document', { status: 404 })
      },
      config: { dataset: 'staging' },
    }
    const { container } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'x', _type: 'post' }}
        client={client}
        notFound={<div data-testid="nf">missing</div>}
        errorFallback={<div data-testid="ef">failed</div>}
        onError={onError}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(container.innerHTML).toContain('missing')
    expect(onError).not.toHaveBeenCalled()
  })

  it('UNCHANGED: doc() returning null is still a miss', async () => {
    const { container } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'x', _type: 'post' }}
        client={docClient(404)}
        notFound={<div data-testid="nf">missing</div>}
        errorFallback={<div data-testid="ef">failed</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(container.innerHTML).toContain('missing')
  })

  for (const status of NON_OK) {
    it(`fetchRaw branch: ${status} takes the error path, NOT notFound`, async () => {
      const onError = vi.fn()
      const { container } = await renderAsync(
        <BarkparkReference
          ref={{ _ref: 'x', _type: 'post' }}
          client={rawClient(status)}
          notFound={<div data-testid="nf">missing</div>}
          errorFallback={<div data-testid="ef">failed</div>}
          onError={onError}
        >
          {renderDoc}
        </BarkparkReference>,
      )
      expect(container.innerHTML).toContain('failed')
      expect(container.innerHTML).not.toContain('missing')
      expect(onError).toHaveBeenCalled()
      // No core error object exists on this branch — only a Response — so the
      // fetcher throws its own typed error carrying the status AND the url.
      const [err, erroredId] = onError.mock.calls[0] as [BarkparkReferenceFetchError, string]
      expect(err.code).toBe('BarkparkReferenceFetchError')
      expect(err.status).toBe(status)
      expect(err.url).toBe('/w/acme/p/blog/v1/data/doc/staging/post/x')
      expect(erroredId).toBe('x')
    })

    it(`doc() branch: ${status} rethrows the core error, NOT notFound`, async () => {
      const onError = vi.fn()
      const { container } = await renderAsync(
        <BarkparkReference
          ref={{ _ref: 'x', _type: 'post' }}
          client={docClient(status)}
          notFound={<div data-testid="nf">missing</div>}
          errorFallback={<div data-testid="ef">failed</div>}
          onError={onError}
        >
          {renderDoc}
        </BarkparkReference>,
      )
      expect(container.innerHTML).toContain('failed')
      expect(container.innerHTML).not.toContain('missing')
      expect(onError).toHaveBeenCalled()
      // The core error is passed through untouched — the component adds no
      // wrapper on this branch, it only refuses to swallow.
      const [err] = onError.mock.calls[0] as [{ code?: string; status?: number }]
      expect(err.code).toBe(
        status === 429
          ? 'BarkparkRateLimitError'
          : status < 500
            ? 'BarkparkAuthError'
            : 'BarkparkAPIError',
      )
      expect(err.status).toBe(status)
    })
  }

  it('discriminates by `code`, not `instanceof` (a duplicated core copy still reads as a miss)', async () => {
    // pnpm hoist can give the app a SECOND copy of @barkpark/core, so a real
    // BarkparkNotFoundError may fail `instanceof` against the imported class.
    // A structural stand-in reproduces that: only `code` identifies it.
    const hoistedDuplicate = Object.assign(new Error('no such document'), {
      code: 'BarkparkNotFoundError',
      status: 404,
    })
    expect(hoistedDuplicate instanceof BarkparkNotFoundError).toBe(false)
    const client: BarkparkReferenceClient = {
      doc: async () => {
        throw hoistedDuplicate
      },
      config: { dataset: 'staging' },
    }
    const { container } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'x', _type: 'post' }}
        client={client}
        notFound={<div data-testid="nf">missing</div>}
        errorFallback={<div data-testid="ef">failed</div>}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(container.innerHTML).toContain('missing')
  })

  it('a JSON-decode failure is an error too, not a silent miss', async () => {
    const onError = vi.fn()
    const client: BarkparkReferenceClient = {
      fetchRaw: async <T = Response>(): Promise<T> =>
        new Response('not json', {
          status: 200,
          headers: { 'content-type': 'application/json' },
        }) as T,
      config: { dataset: 'staging' },
    }
    const { container } = await renderAsync(
      <BarkparkReference
        ref={{ _ref: 'x', _type: 'post' }}
        client={client}
        notFound={<div data-testid="nf">missing</div>}
        errorFallback={<div data-testid="ef">failed</div>}
        onError={onError}
      >
        {renderDoc}
      </BarkparkReference>,
    )
    expect(container.innerHTML).toContain('failed')
    expect(onError).toHaveBeenCalled()
  })

  // THE SAFE LANDING — load-bearing, not decorative. MEASURED on React 19 in
  // this very suite: a consumer <ErrorBoundary> catches a plain synchronous
  // throw, but catches NEITHER a throw in the render resumed after `use()` NOR
  // a rejected promise passed to `use()` — both leave the subtree permanently
  // unsettled (test timeouts at 5000ms, empty container, componentDidCatch
  // never called). So the failure is handled INSIDE the component: rethrowing
  // for a consumer boundary is not an option React actually offers here.
  it('renders errorFallback with NO error boundary anywhere in the tree, and settles', async () => {
    const started = Date.now()
    // The console receipt still fires (no onError); silence it so the suite
    // output stays clean — it is asserted in its own test below.
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      const { container } = await renderAsync(
        <BarkparkReference
          ref={{ _ref: 'x', _type: 'post' }}
          client={rawClient(500)}
          errorFallback={<div data-testid="ef">Could not load this reference.</div>}
        >
          {renderDoc}
        </BarkparkReference>,
      )
      expect(container.innerHTML).toContain('Could not load this reference.')
    } finally {
      spy.mockRestore()
    }
    // A hang would blow the 5s test timeout; the explicit bound makes a future
    // regression to the never-settling path fail loudly right here.
    expect(Date.now() - started).toBeLessThan(2000)
  })

  it('with neither errorFallback nor onError, the failure still leaves a console receipt', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    try {
      const { container } = await renderAsync(
        <BarkparkReference
          ref={{ _ref: 'x', _type: 'post' }}
          client={rawClient(500)}
          notFound={<div data-testid="nf">missing</div>}
        >
          {renderDoc}
        </BarkparkReference>,
      )
      // Nothing is asserted about the document — and crucially NOT `notFound`.
      expect(container.innerHTML).not.toContain('missing')
      expect(spy).toHaveBeenCalled()
      const [msg, err] = spy.mock.calls[0] as [string, BarkparkReferenceFetchError]
      expect(msg).toContain('BarkparkReference: x failed')
      expect(msg).toContain('errorFallback')
      expect(err.status).toBe(500)
    } finally {
      spy.mockRestore()
    }
  })
})
