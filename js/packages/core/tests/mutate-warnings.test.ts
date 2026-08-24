import { describe, it, expect } from 'vitest'
import type { BarkparkClientConfig, MutateEnvelope, MutateWarning } from '../src/types'
import { createClient } from '../src/client'
import { publishDoc, unpublishDoc, discardDraftDoc } from '../src/publish'
import { createPatch } from '../src/patch'
import { BarkparkValidationError } from '../src/errors'

// [publish-warnings-dropped] The publish wall queues NON-BLOCKING advisories
// while a write applies (the label-spine tag-count norm, the E4 dedup wall's
// advise band, the task plugin's merge-gate notice) and MutateController drains
// them onto the 200 body as `warnings` (mutate_controller.ex). The four
// single-mutation helpers — publish / unpublish / discardDraft / patch().commit()
// — narrowed that envelope to `results[0]` and dropped `warnings` on the floor.
// `MutateEnvelope.warnings` was DECLARED in types.ts and read by no runtime path
// in this package, so the calls the advisory channel exists for were the only
// calls that could not see it: the write reported clean, and the wall's advice
// reached nobody. `client.create/replace/delete` never had it — they return the
// whole envelope.
//
// These tests pin BOTH halves: the advisories now arrive, AND the absence of
// advisories is still an ABSENT key (not an empty array), so `'warnings' in
// result` stays a real test rather than one that is always true.

const ADVICE: MutateWarning[] = [
  { code: 'tag_count_norm', severity: 'advisory', message: 'papers carry 2–4 tags' },
  // The E4 dedup wall stamps the SHARPER band (dedup_wall.ex :: warning/1 — a
  // SYMBOL, not a line number: the `:524` this used to carry went stale as soon
  // as anything above it moved, and the doc-anchor gate caught it on the very
  // next PR). The SDK type
  // declared `severity: 'advisory'` alone, which made this literal unassignable
  // and `severity === 'warning'` a compile error — the client type was NARROWER
  // than the wire. Delete `'warning'` from the union in types.ts and tsc reds here.
  { code: 'near_duplicate', severity: 'warning', message: 'looks like paper-abc' },
]

const RESULT = {
  id: 'paper-1',
  operation: 'publish' as const,
  document: {
    _id: 'paper-1',
    _type: 'paper',
    _rev: 'r2',
    _draft: false,
    _publishedId: 'paper-1',
    _createdAt: '2026-08-24T09:00:00Z',
    _updatedAt: '2026-08-24T09:00:00Z',
  },
}

interface Spy {
  config: BarkparkClientConfig
  bodies: unknown[]
}

/** Spy fetch returning one canned mutate envelope and capturing request bodies. */
function spy(envelope: MutateEnvelope): Spy {
  const bodies: unknown[] = []
  const fetchImpl: typeof globalThis.fetch = async (_input, init) => {
    bodies.push(typeof init?.body === 'string' ? JSON.parse(init.body) : init?.body)
    return new Response(JSON.stringify(envelope), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })
  }
  return {
    config: {
      projectUrl: 'http://spy.local',
      dataset: 'production',
      apiVersion: '2026-04-17',
      token: 't',
      fetch: fetchImpl,
    },
    bodies,
  }
}

const withAdvice: MutateEnvelope = { transactionId: 'tx1', results: [RESULT], warnings: ADVICE }
// The server OMITS the key when the drain came back empty (mutate_controller.ex
// only Map.put's it for a non-empty list) — so the clean case has no key at all.
const clean: MutateEnvelope = { transactionId: 'tx2', results: [RESULT] }

describe('publish-lifecycle helpers carry the envelope advisories', () => {
  it('publishDoc surfaces every warning the write raised, in order', async () => {
    const s = spy(withAdvice)
    const result = await publishDoc(s.config, 'paper-1', 'paper')
    expect(result.warnings).toEqual(ADVICE)
    expect(result.warnings?.map((w) => w.code)).toEqual(['tag_count_norm', 'near_duplicate'])
    // The result itself is otherwise untouched — carrying advice must not
    // reshape the receipt.
    expect(result.id).toBe('paper-1')
    expect(result.operation).toBe('publish')
    expect(result.document._rev).toBe('r2')
  })

  it('unpublishDoc and discardDraftDoc carry them too', async () => {
    const a = spy(withAdvice)
    expect((await unpublishDoc(a.config, 'paper-1', 'paper')).warnings).toEqual(ADVICE)
    const b = spy(withAdvice)
    expect((await discardDraftDoc(b.config, 'paper-1', 'paper')).warnings).toEqual(ADVICE)
  })

  it('patch().commit() carries them — the fourth narrowing site', async () => {
    const s = spy(withAdvice)
    const result = await createPatch(s.config, 'paper-1', 'paper').set({ title: 'x' }).commit()
    expect(result.warnings).toEqual(ADVICE)
  })

  it('client.publish/unpublish/discardDraft expose them through the public surface', async () => {
    const s = spy(withAdvice)
    const bp = createClient(s.config)
    expect((await bp.publish('paper-1', 'paper')).warnings).toEqual(ADVICE)
    expect((await bp.unpublish('paper-1', 'paper')).warnings).toEqual(ADVICE)
    expect((await bp.discardDraft('paper-1', 'paper')).warnings).toEqual(ADVICE)
  })

  it('a clean write leaves the key ABSENT, not an empty array', async () => {
    const s = spy(clean)
    const result = await publishDoc(s.config, 'paper-1', 'paper')
    // `'warnings' in result` must distinguish advised from clean. An `?? []`
    // default would make this key always present and the test meaningless.
    expect('warnings' in result).toBe(false)
    expect(result.warnings).toBeUndefined()
  })

  it('an explicitly empty server list is still absence, not advice', async () => {
    const s = spy({ transactionId: 'tx3', results: [RESULT], warnings: [] })
    expect('warnings' in (await publishDoc(s.config, 'paper-1', 'paper'))).toBe(false)
  })
})

// The three helpers were three byte-identical copies; they now share one
// request builder so the carry-through fits the gzipped bundle budget. These
// pin what the fold must not have changed.
describe('the folded lifecycle helpers keep their exact wire and error contract', () => {
  it('each still POSTs its own mutation key to the mutate endpoint', async () => {
    const p = spy(clean)
    await publishDoc(p.config, 'p1', 'paper')
    expect(p.bodies[0]).toEqual({ mutations: [{ publish: { id: 'p1', type: 'paper' } }] })

    const u = spy(clean)
    await unpublishDoc(u.config, 'p1', 'paper')
    expect(u.bodies[0]).toEqual({ mutations: [{ unpublish: { id: 'p1', type: 'paper' } }] })

    const d = spy(clean)
    await discardDraftDoc(d.config, 'p1', 'paper')
    expect(d.bodies[0]).toEqual({ mutations: [{ discardDraft: { id: 'p1', type: 'paper' } }] })
  })

  it('keeps each helper’s own validation message and field', async () => {
    const s = spy(clean)
    await expect(publishDoc(s.config, '', 'paper')).rejects.toThrow(
      'publishDoc requires id and type',
    )
    await expect(unpublishDoc(s.config, '', 'paper')).rejects.toThrow(
      'unpublishDoc requires id and type',
    )
    await expect(discardDraftDoc(s.config, 'p1', '')).rejects.toThrow(
      'discardDraftDoc requires id and type',
    )
    await expect(publishDoc(s.config, 'p1', '')).rejects.toMatchObject({ field: 'type' })
    expect(s.bodies).toHaveLength(0) // fails closed BEFORE the request
  })

  it('an empty results set is still a typed BarkparkValidationError naming the op', async () => {
    const s = spy({ transactionId: 'tx4', results: [] })
    await expect(publishDoc(s.config, 'p1', 'paper')).rejects.toBeInstanceOf(
      BarkparkValidationError,
    )
    const t = spy({ transactionId: 'tx4', results: [] })
    await expect(unpublishDoc(t.config, 'p1', 'paper')).rejects.toThrow(
      'unpublish: server returned empty results',
    )
  })
})
