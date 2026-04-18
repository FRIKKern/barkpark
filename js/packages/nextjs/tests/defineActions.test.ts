// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { BarkparkConflictError } from '@barkpark/core'

// Minimal duck-typed "Zod schema" — exercises the .parse() contract without
// pulling the real zod package into the test. The production code only calls
// `.parse(input)`, so this is behaviourally equivalent.
interface FakeSchema {
  parse: (input: unknown) => unknown
}
class FakeValidationError extends Error {
  readonly issues: Array<{ path: string[]; message: string }>
  constructor(issues: Array<{ path: string[]; message: string }>) {
    super('FakeValidationError')
    this.issues = issues
  }
}
function makeSchema(predicate: (input: unknown) => true | string): FakeSchema {
  return {
    parse(input) {
      const check = predicate(input)
      if (check === true) return input
      throw new FakeValidationError([{ path: [], message: check }])
    },
  }
}

// Use vi.hoisted so the spy exists when vi.mock runs (it is hoisted above imports).
const { revalidateTag } = vi.hoisted(() => ({
  revalidateTag: vi.fn<(tag: string) => void>(),
}))
vi.mock('next/cache', () => ({ revalidateTag }))

import { defineActions } from '../src/actions/defineActions'
import type { BarkparkClient, MutateEnvelope, MutateResult } from '@barkpark/core'

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

function makeResult(overrides: Partial<MutateResult> = {}): MutateResult {
  return {
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
    ...overrides,
  }
}

interface MockClient {
  client: BarkparkClient
  calls: {
    txCreate: Array<Record<string, unknown>>
    patchSet: Array<Record<string, unknown>>
    commit: Array<{ ifMatch?: string } | undefined>
    publish: Array<[string, string]>
    unpublish: Array<[string, string]>
  }
}

function makeClient(opts: {
  mutateResult?: MutateResult
  publishResult?: MutateResult
  unpublishResult?: MutateResult
  commitError?: unknown
} = {}): MockClient {
  const calls: MockClient['calls'] = {
    txCreate: [],
    patchSet: [],
    commit: [],
    publish: [],
    unpublish: [],
  }

  const mutateResult = opts.mutateResult ?? makeResult()
  const publishResult = opts.publishResult ?? makeResult({ operation: 'publish' })
  const unpublishResult = opts.unpublishResult ?? makeResult({ operation: 'unpublish' })

  const envelope: MutateEnvelope = { transactionId: 'tx1', results: [mutateResult] }

  const txBuilder = {
    create(doc: Record<string, unknown>) {
      calls.txCreate.push(doc)
      return txBuilder
    },
    createOrReplace() { return txBuilder },
    patch() { return txBuilder },
    publish() { return txBuilder },
    unpublish() { return txBuilder },
    delete() { return txBuilder },
    async commit(commitOpts?: { ifMatch?: string }) {
      calls.commit.push(commitOpts)
      if (opts.commitError !== undefined) throw opts.commitError
      return envelope
    },
  }

  const patchBuilder = {
    set(fields: Record<string, unknown>) {
      calls.patchSet.push(fields)
      return patchBuilder
    },
    inc() { return patchBuilder },
    async commit(commitOpts?: { ifMatch?: string }) {
      calls.commit.push(commitOpts)
      if (opts.commitError !== undefined) throw opts.commitError
      return mutateResult
    },
  }

  const client = {
    config: {
      projectUrl: 'http://localhost:4000',
      dataset: 'production',
      apiVersion: '2026-04-01',
    },
    withConfig() { return client as unknown as BarkparkClient },
    async doc() { return null },
    docs() { throw new Error('not used') },
    patch() { return patchBuilder },
    transaction() { return txBuilder },
    async publish(id: string, type: string) {
      calls.publish.push([id, type])
      if (opts.commitError !== undefined) throw opts.commitError
      return publishResult
    },
    async unpublish(id: string, type: string) {
      calls.unpublish.push([id, type])
      if (opts.commitError !== undefined) throw opts.commitError
      return unpublishResult
    },
    listen() { throw new Error('not used') },
    async fetchRaw() { return undefined },
  } as unknown as BarkparkClient

  return { client, calls }
}

beforeEach(() => {
  revalidateTag.mockClear()
})

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('defineActions', () => {
  describe('createDoc', () => {
    it('passes through without schema and fans out doc + type tags', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      const result = await actions.createDoc({ _type: 'post', title: 'hello' })

      expect(result.id).toBe('p1')
      expect(calls.txCreate).toEqual([{ _type: 'post', title: 'hello' }])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
      expect(revalidateTag).toHaveBeenCalledTimes(2)
    })

    it('invokes a matching Zod schema before delegating to core (pass path)', async () => {
      const { client, calls } = makeClient()
      const parseSpy = vi.fn((input: unknown) => input)
      const schema: FakeSchema = { parse: parseSpy }
      const actions = defineActions({ client, schemas: { post: schema } })

      await expect(
        actions.createDoc({ _type: 'post', title: 'hi' }),
      ).resolves.toMatchObject({ id: 'p1' })
      expect(parseSpy).toHaveBeenCalledWith({ _type: 'post', title: 'hi' })
      expect(calls.txCreate).toHaveLength(1)
    })

    it('propagates validation errors without calling core or revalidating', async () => {
      const { client, calls } = makeClient()
      const schema = makeSchema((input) => {
        const rec = input as Record<string, unknown>
        return typeof rec['title'] === 'string' ? true : 'title must be a string'
      })
      const actions = defineActions({ client, schemas: { post: schema } })

      await expect(
        actions.createDoc({ _type: 'post', title: 123 }),
      ).rejects.toThrow(FakeValidationError)

      expect(calls.txCreate).toHaveLength(0)
      expect(revalidateTag).not.toHaveBeenCalled()
    })

    it('honors an explicit dataset override when formatting tags', async () => {
      const { client } = makeClient()
      const actions = defineActions({ client, dataset: 'staging' })
      await actions.createDoc({ _type: 'post' })

      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:staging:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:staging:type:post')
    })
  })

  describe('patchDoc', () => {
    it('passes set + ifMatch through to the fluent builder', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      const result = await actions.patchDoc('p1', {
        set: { title: 'new' },
        ifMatch: 'rev-abc',
      })

      expect(result.id).toBe('p1')
      expect(calls.patchSet).toEqual([{ title: 'new' }])
      expect(calls.commit).toEqual([{ ifMatch: 'rev-abc' }])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    })

    it('propagates BarkparkConflictError unmodified', async () => {
      const conflict = new BarkparkConflictError('stale rev', {
        status: 412,
        serverEtag: 'rev-xyz',
      })
      const { client } = makeClient({ commitError: conflict })
      const actions = defineActions({ client })

      await expect(
        actions.patchDoc('p1', { set: { title: 'x' }, ifMatch: 'rev-old' }),
      ).rejects.toBe(conflict)
      expect(revalidateTag).not.toHaveBeenCalled()
    })
  })

  describe('publish / unpublish', () => {
    it('publish fans out tags for the given id + type', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      await actions.publish('p1', 'post')

      expect(calls.publish).toEqual([['p1', 'post']])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    })

    it('unpublish fans out tags for the given id + type', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      await actions.unpublish('p1', 'post')

      expect(calls.unpublish).toEqual([['p1', 'post']])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    })
  })
})
