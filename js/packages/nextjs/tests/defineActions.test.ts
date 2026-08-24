// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { BarkparkConflictError, BarkparkValidationError, isBarkparkError } from '@barkpark/core'

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
import type {
  BarkparkClient,
  MutateEnvelope,
  MutateResult,
  MutateWarning,
} from '@barkpark/core'

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
    txDelete: Array<[string, string]>
    /** (id, type) handed to client.patch() — `type` is required by the server. */
    patchTarget: Array<[string, string]>
    patchSet: Array<Record<string, unknown>>
    patchSetIfMissing: Array<Record<string, unknown>>
    patchUnset: string[][]
    patchInc: Array<Record<string, number>>
    patchDec: Array<Record<string, number>>
    patchAppend: Array<[string, unknown[]]>
    patchPrepend: Array<[string, unknown[]]>
    commit: Array<{ ifMatch?: string } | undefined>
    publish: Array<[string, string]>
    unpublish: Array<[string, string]>
    discardDraft: Array<[string, string]>
  }
}

function makeClient(
  opts: {
    mutateResult?: MutateResult
    publishResult?: MutateResult
    unpublishResult?: MutateResult
    commitError?: unknown
    emptyResults?: boolean
    /** Publish-wall advisories riding the transaction envelope (mutate_controller.ex). */
    envelopeWarnings?: MutateWarning[]
    scope?: { workspace?: string; project?: string }
  } = {},
): MockClient {
  const calls: MockClient['calls'] = {
    txCreate: [],
    txDelete: [],
    patchTarget: [],
    patchSet: [],
    patchSetIfMissing: [],
    patchUnset: [],
    patchInc: [],
    patchDec: [],
    patchAppend: [],
    patchPrepend: [],
    commit: [],
    publish: [],
    unpublish: [],
    discardDraft: [],
  }

  const mutateResult = opts.mutateResult ?? makeResult()
  const publishResult = opts.publishResult ?? makeResult({ operation: 'publish' })
  const unpublishResult = opts.unpublishResult ?? makeResult({ operation: 'unpublish' })
  const discardDraftResult = makeResult({ operation: 'discardDraft' })

  // The server OMITS `warnings` when the drain came back empty, so the default
  // envelope must not carry the key at all — spreading an always-present `[]`
  // here would make the absence assertion below vacuous.
  const envelope: MutateEnvelope = {
    transactionId: 'tx1',
    results: opts.emptyResults === true ? [] : [mutateResult],
    ...(opts.envelopeWarnings !== undefined ? { warnings: opts.envelopeWarnings } : {}),
  }

  const txBuilder = {
    create(doc: Record<string, unknown>) {
      calls.txCreate.push(doc)
      return txBuilder
    },
    createOrReplace() {
      return txBuilder
    },
    patch() {
      return txBuilder
    },
    publish() {
      return txBuilder
    },
    unpublish() {
      return txBuilder
    },
    delete(id: string, type: string) {
      calls.txDelete.push([id, type])
      return txBuilder
    },
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
    setIfMissing(fields: Record<string, unknown>) {
      calls.patchSetIfMissing.push(fields)
      return patchBuilder
    },
    unset(keys: string[]) {
      calls.patchUnset.push(keys)
      return patchBuilder
    },
    inc(fields: Record<string, number>) {
      calls.patchInc.push(fields)
      return patchBuilder
    },
    dec(fields: Record<string, number>) {
      calls.patchDec.push(fields)
      return patchBuilder
    },
    append(selector: string, items: unknown[]) {
      calls.patchAppend.push([selector, items])
      return patchBuilder
    },
    prepend(selector: string, items: unknown[]) {
      calls.patchPrepend.push([selector, items])
      return patchBuilder
    },
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
      ...(opts.scope ?? {}),
    },
    withConfig() {
      return client as unknown as BarkparkClient
    },
    async doc() {
      return null
    },
    docs() {
      throw new Error('not used')
    },
    patch(id: string, type: string) {
      calls.patchTarget.push([id, type])
      return patchBuilder
    },
    transaction() {
      return txBuilder
    },
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
    async discardDraft(id: string, type: string) {
      calls.discardDraft.push([id, type])
      if (opts.commitError !== undefined) throw opts.commitError
      return discardDraftResult
    },
    listen() {
      throw new Error('not used')
    },
    async fetchRaw() {
      return undefined
    },
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

      await expect(actions.createDoc({ _type: 'post', title: 'hi' })).resolves.toMatchObject({
        id: 'p1',
      })
      expect(parseSpy).toHaveBeenCalledWith({ _type: 'post', title: 'hi' })
      expect(calls.txCreate).toHaveLength(1)
    })

    it('persists the schema-transformed value (parse result), re-pinning _type', async () => {
      const { client, calls } = makeClient()
      // A schema whose parse TRANSFORMS: lowercases/trims title, fills a default,
      // and strips the discriminant (as Zod does for unknown keys by default).
      const schema: FakeSchema = {
        parse(input) {
          const rec = input as Record<string, unknown>
          return {
            title: String(rec['title']).trim().toLowerCase(),
            status: 'draft',
          }
        },
      }
      const actions = defineActions({ client, schemas: { post: schema } })

      await actions.createDoc({ _type: 'post', title: '  HeLLo  ' })

      // The create body carries the TRANSFORMED values plus the original _type.
      expect(calls.txCreate).toEqual([{ _type: 'post', title: 'hello', status: 'draft' }])
      // Tags still key off _type.
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    })

    it('propagates validation errors without calling core or revalidating', async () => {
      const { client, calls } = makeClient()
      const schema = makeSchema((input) => {
        const rec = input as Record<string, unknown>
        return typeof rec['title'] === 'string' ? true : 'title must be a string'
      })
      const actions = defineActions({ client, schemas: { post: schema } })

      await expect(actions.createDoc({ _type: 'post', title: 123 })).rejects.toThrow(
        FakeValidationError,
      )

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

    it('throws a BarkparkError (not a bare Error) on an empty mutate envelope', async () => {
      const { client } = makeClient({ emptyResults: true })
      const actions = defineActions({ client })

      // Honors the 'every failure is a BarkparkError' contract so consumers'
      // cross-bundle-safe `isBarkparkError(e)` boundary catches this edge.
      await expect(actions.createDoc({ _type: 'post' })).rejects.toSatisfy(isBarkparkError)
      expect(revalidateTag).not.toHaveBeenCalled()
    })

    it('fails closed on an empty _type — no create, no garbage revalidate', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      // Reachable from untyped form/JSON input. An empty _type would skip schema
      // validation AND fire a `bp:ds:production:type:` tag that matches no read tag,
      // silently losing the intended invalidation — so we reject before either.
      await expect(
        actions.createDoc({ _type: '' } as unknown as { _type: string }),
      ).rejects.toBeInstanceOf(BarkparkValidationError)

      expect(calls.txCreate).toHaveLength(0)
      expect(revalidateTag).not.toHaveBeenCalled()
    })

    it('rejects rather than sending a corrupt body when schema.parse returns a non-object', async () => {
      // A schema whose top-level parse returns a STRING (via .transform()/z.string()):
      // spreading it would corrupt the create body (`{0:'h',1:'i'}`), so we reject.
      const { client, calls } = makeClient()
      const stringSchema: FakeSchema = { parse: () => 'hi' }
      const stringActions = defineActions({ client, schemas: { post: stringSchema } })

      await expect(stringActions.createDoc({ _type: 'post' })).rejects.toBeInstanceOf(
        BarkparkValidationError,
      )
      expect(calls.txCreate).toHaveLength(0)
      expect(revalidateTag).not.toHaveBeenCalled()

      // Same guard for an ARRAY-returning parse.
      const arraySchema: FakeSchema = { parse: () => ['a', 'b'] }
      const arrayActions = defineActions({ client, schemas: { post: arraySchema } })

      await expect(arrayActions.createDoc({ _type: 'post' })).rejects.toBeInstanceOf(
        BarkparkValidationError,
      )
      expect(calls.txCreate).toHaveLength(0)
      expect(revalidateTag).not.toHaveBeenCalled()
    })
  })

  describe('patchDoc', () => {
    it('passes set + ifMatch through to the fluent builder', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      const result = await actions.patchDoc('p1', 'post', {
        set: { title: 'new' },
        ifMatch: 'rev-abc',
      })

      // The server dispatches a patch op on (id, type) and 400s without `type`
      // (api-v1.md §6), so patchDoc must forward it to the builder.
      expect(calls.patchTarget).toEqual([['p1', 'post']])

      expect(result.id).toBe('p1')
      expect(calls.patchSet).toEqual([{ title: 'new' }])
      expect(calls.commit).toEqual([{ ifMatch: 'rev-abc' }])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    })

    it('threads the full Phase-1B op set through to the builder', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      await actions.patchDoc('p1', 'post', {
        set: { title: 'new' },
        setIfMissing: { views: 0 },
        unset: ['legacy'],
        inc: { views: 1 },
        dec: { stock: 2 },
        append: { tags: ['x'] },
        prepend: { authors: ['a'] },
      })

      expect(calls.patchSet).toEqual([{ title: 'new' }])
      expect(calls.patchSetIfMissing).toEqual([{ views: 0 }])
      expect(calls.patchUnset).toEqual([['legacy']])
      expect(calls.patchInc).toEqual([{ views: 1 }])
      expect(calls.patchDec).toEqual([{ stock: 2 }])
      expect(calls.patchAppend).toEqual([['tags', ['x']]])
      expect(calls.patchPrepend).toEqual([['authors', ['a']]])
    })

    it('omits ops that are absent or empty (no stray builder calls)', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      await actions.patchDoc('p1', 'post', { inc: { views: 1 } })

      expect(calls.patchSet).toEqual([])
      expect(calls.patchInc).toEqual([{ views: 1 }])
      expect(calls.patchUnset).toEqual([])
    })

    it('propagates BarkparkConflictError unmodified', async () => {
      const conflict = new BarkparkConflictError('stale rev', {
        status: 412,
        serverEtag: 'rev-xyz',
      })
      const { client } = makeClient({ commitError: conflict })
      const actions = defineActions({ client })

      await expect(
        actions.patchDoc('p1', 'post', { set: { title: 'x' }, ifMatch: 'rev-old' }),
      ).rejects.toBe(conflict)
      expect(revalidateTag).not.toHaveBeenCalled()
    })
  })

  describe('cache-tag namespace (scoped vs flat)', () => {
    it('flat bp:ds:* tags when workspace+project NOT configured (back-compat)', async () => {
      const { client } = makeClient()
      const actions = defineActions({ client })
      await actions.createDoc({ _type: 'post' })

      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
      const calls = revalidateTag.mock.calls.map((c) => String(c[0]))
      for (const t of calls) expect(t).not.toContain('bp:ws:')
    })

    it('scoped bp:ws:<ws>:p:<project>:ds:* tags when client.config has workspace+project', async () => {
      const { client } = makeClient({ scope: { workspace: 'acme', project: 'blog' } })
      const actions = defineActions({ client })
      await actions.createDoc({ _type: 'post' })

      expect(revalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:type:post')
      // Generated grammar MUST match what the s15 revalidate ingest parses.
      const calls = revalidateTag.mock.calls.map((c) => String(c[0]))
      for (const t of calls)
        expect(t).toMatch(/^bp:ws:acme:p:blog:ds:production:(?:doc:.+|type:.+)$/)
    })

    it('config workspace/project override the client config values', async () => {
      const { client } = makeClient({ scope: { workspace: 'acme', project: 'blog' } })
      const actions = defineActions({ client, workspace: 'ws2', project: 'pr2' })
      await actions.publish('p1', 'post')

      expect(revalidateTag).toHaveBeenCalledWith('bp:ws:ws2:p:pr2:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ws:ws2:p:pr2:ds:production:type:post')
    })

    it('flat tags when only workspace resolves (both required, mirrors scopePrefix)', async () => {
      const { client } = makeClient({ scope: { workspace: 'acme' } })
      const actions = defineActions({ client })
      await actions.unpublish('p1', 'post')

      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
      const calls = revalidateTag.mock.calls.map((c) => String(c[0]))
      for (const t of calls) expect(t).not.toContain('bp:ws:')
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

  describe('deleteDoc', () => {
    it('deletes via a transaction and fans out doc + type tags', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      const result = await actions.deleteDoc('p1', 'post')

      expect(result.id).toBe('p1')
      expect(calls.txDelete).toEqual([['p1', 'post']])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
      expect(revalidateTag).toHaveBeenCalledTimes(2)
    })

    it('throws a BarkparkError (not a bare Error) on an empty mutate envelope', async () => {
      const { client } = makeClient({ emptyResults: true })
      const actions = defineActions({ client })

      await expect(actions.deleteDoc('p1', 'post')).rejects.toSatisfy(isBarkparkError)
      expect(revalidateTag).not.toHaveBeenCalled()
    })
  })

  describe('discardDraft', () => {
    it('discards the draft and fans out doc + type tags', async () => {
      const { client, calls } = makeClient()
      const actions = defineActions({ client })

      const result = await actions.discardDraft('p1', 'post')

      expect(result.operation).toBe('discardDraft')
      expect(calls.discardDraft).toEqual([['p1', 'post']])
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
      expect(revalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
      expect(revalidateTag).toHaveBeenCalledTimes(2)
    })
  })

  // [publish-warnings-dropped] `createDoc` / `deleteDoc` commit a transaction and
  // then narrow the envelope to `results[0]` — which threw away the publish
  // wall's non-blocking `warnings`. The other four actions call a core
  // single-mutation helper, so core's `onlyResult` now carries advisories for
  // them; these two narrow the envelope here and had to carry them here.
  describe('publish-wall advisories survive the envelope narrowing', () => {
    const advice: MutateWarning[] = [
      { code: 'tag_count_norm', severity: 'advisory', message: 'papers carry 2–4 tags' },
      { code: 'near_duplicate', severity: 'warning', message: 'looks like p0' },
    ]

    it('createDoc carries them onto the returned result', async () => {
      const { client } = makeClient({ envelopeWarnings: advice })
      const result = await defineActions({ client }).createDoc({ _type: 'post', title: 'x' })
      expect(result.warnings).toEqual(advice)
    })

    it('deleteDoc carries them onto the returned result', async () => {
      const { client } = makeClient({ envelopeWarnings: advice })
      const result = await defineActions({ client }).deleteDoc('p1', 'post')
      expect(result.warnings).toEqual(advice)
    })

    it('a clean write leaves the key ABSENT, not an empty array', async () => {
      const { client } = makeClient()
      const actions = defineActions({ client })
      expect('warnings' in (await actions.createDoc({ _type: 'post', title: 'x' }))).toBe(false)
      expect('warnings' in (await actions.deleteDoc('p1', 'post'))).toBe(false)
    })

    it('an explicitly empty server list is still absence, not advice', async () => {
      const { client } = makeClient({ envelopeWarnings: [] })
      expect('warnings' in (await defineActions({ client }).deleteDoc('p1', 'post'))).toBe(false)
    })
  })
})
