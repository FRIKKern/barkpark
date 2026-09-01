// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// CAPABILITY: `createDoc({ _type: … })` reaches the schema REGISTERED under
// that `_type`, or none at all — a `_type` that merely names something on
// `Object.prototype` is treated as unregistered, exactly like any other
// unknown type.
//
// The lookup was `schemas?.[input._type]` on a plain codegen object literal —
// a prototype-chain read. `_type: 'toString'` / 'constructor' / 'valueOf' /
// '__proto__' all resolved to an INHERITED value, whose `.parse` is not a
// function, so `schema.parse(input)` threw a raw `TypeError` out of a Server
// Action. `_type` is reachable from untyped form/JSON input — the comment three
// lines above the lookup says so — and this package ships CJS/ESM to plain JS
// consumers, so the `Record<string, ActionSchema>` type closes nothing.
//
// This is a CRASH, not a validation bypass: no inherited value carries a
// callable `.parse`, so nothing was ever validated-then-waved-through. The
// defect is that the raw TypeError escapes the Barkpark error taxonomy — the
// exact class this codebase names in its own comments (see the `details: null`
// note in server/core.ts's decodeAndThrow).

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { BarkparkValidationError, isBarkparkError } from '@barkpark/core'
import type { BarkparkClient, MutateEnvelope } from '@barkpark/core'

const { revalidateTag } = vi.hoisted(() => ({
  revalidateTag: vi.fn<(tag: string) => void>(),
}))
vi.mock('next/cache', () => ({ revalidateTag }))

import { defineActions } from '../src/actions/defineActions'
import type { ActionSchema } from '../src/actions/defineActions'

interface Harness {
  client: BarkparkClient
  created: Array<Record<string, unknown>>
}

function makeClient(): Harness {
  const created: Array<Record<string, unknown>> = []
  const envelope: MutateEnvelope = {
    transactionId: 'tx1',
    results: [
      {
        id: 'p1',
        operation: 'create',
        document: {
          _id: 'p1',
          _type: 'post',
          _rev: 'r1',
          _draft: false,
          _publishedId: 'p1',
          _createdAt: '2026-01-01T00:00:00Z',
          _updatedAt: '2026-01-01T00:00:00Z',
        },
      },
    ],
  }
  const tx = {
    create(doc: Record<string, unknown>) {
      created.push(doc)
      return tx
    },
    async commit() {
      return envelope
    },
  }
  const client = {
    config: { projectUrl: 'http://localhost:4000', dataset: 'production', apiVersion: '2026-01-01' },
    transaction: () => tx,
  } as unknown as BarkparkClient
  return { client, created }
}

beforeEach(() => {
  revalidateTag.mockReset()
})

describe('defineActions.createDoc — the schema lookup is own-key only', () => {
  it('CONTROL: a REGISTERED _type still routes to its schema and the parsed value is persisted', async () => {
    const parse = vi.fn((input: unknown) => ({ ...(input as object), title: 'trimmed' }))
    const { client, created } = makeClient()
    const actions = defineActions({ client, schemas: { post: { parse } } })
    await actions.createDoc({ _type: 'post', title: '  trimmed  ' })
    expect(parse).toHaveBeenCalledTimes(1)
    expect(created[0]).toEqual({ _type: 'post', title: 'trimmed' })
  })

  it('CONTROL: an unregistered _type skips validation and creates (the intended path)', async () => {
    const parse = vi.fn((input: unknown) => input)
    const { client, created } = makeClient()
    const actions = defineActions({ client, schemas: { post: { parse } } })
    await actions.createDoc({ _type: 'missing', title: 'x' })
    expect(parse).not.toHaveBeenCalled()
    expect(created[0]).toEqual({ _type: 'missing', title: 'x' })
  })

  // Measured against the unfixed lookup: typeof was `function` for the first
  // three and `object` for `__proto__`; every one threw
  // `TypeError: schema.parse is not a function`.
  for (const inherited of ['toString', 'constructor', 'valueOf', '__proto__', 'hasOwnProperty']) {
    it(`_type "${inherited}" is treated as UNREGISTERED — no inherited value is called, no raw TypeError`, async () => {
      const parse = vi.fn((input: unknown) => input)
      const { client, created } = makeClient()
      const actions = defineActions({ client, schemas: { post: { parse } } })
      await actions.createDoc({ _type: inherited, title: 'x' })
      expect(parse).not.toHaveBeenCalled()
      expect(created[0]).toEqual({ _type: inherited, title: 'x' })
    })
  }

  it('a REGISTERED entry whose .parse is not callable raises a BarkparkValidationError, not a raw TypeError', async () => {
    const { client } = makeClient()
    // Plain-JS consumers have no types; a codegen bug or a hand-written map can
    // register a non-schema. Fail inside the taxonomy rather than crashing —
    // and loudly, because silently skipping validation would be a real bypass.
    const actions = defineActions({
      client,
      schemas: { post: {} as unknown as ActionSchema },
    })
    const err = await actions.createDoc({ _type: 'post', title: 'x' }).then(
      () => {
        throw new Error('unexpectedly resolved')
      },
      (e: unknown) => e,
    )
    expect(err).toBeInstanceOf(BarkparkValidationError)
    expect(isBarkparkError(err)).toBe(true)
    expect(err).not.toBeInstanceOf(TypeError)
  })

  it('CONTROL: a schemas map built with a null prototype still resolves its own keys', async () => {
    const parse = vi.fn((input: unknown) => input)
    const schemas = Object.assign(Object.create(null) as Record<string, ActionSchema>, {
      post: { parse },
    })
    const { client } = makeClient()
    const actions = defineActions({ client, schemas })
    await actions.createDoc({ _type: 'post', title: 'x' })
    expect(parse).toHaveBeenCalledTimes(1)
  })
})
