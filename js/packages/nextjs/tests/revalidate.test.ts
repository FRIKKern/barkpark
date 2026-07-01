import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { revalidateTag, revalidatePath } from 'next/cache'
import { revalidateBarkpark } from '../src/revalidate/index'

vi.mock('next/cache', () => ({
  revalidateTag: vi.fn(),
  revalidatePath: vi.fn(),
}))

const mockedRevalidateTag = vi.mocked(revalidateTag)
const mockedRevalidatePath = vi.mocked(revalidatePath)

describe('revalidateBarkpark', () => {
  const originalEnv = process.env.BARKPARK_ALLOW_ALL_REVALIDATE

  beforeEach(() => {
    mockedRevalidateTag.mockClear()
    mockedRevalidatePath.mockClear()
    delete process.env.BARKPARK_ALLOW_ALL_REVALIDATE
  })

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.BARKPARK_ALLOW_ALL_REVALIDATE
    else process.env.BARKPARK_ALLOW_ALL_REVALIDATE = originalEnv
  })

  it('sync_tags present → revalidateTag called with each sync_tag exactly once', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      sync_tags: [
        'bp:ds:production:doc:p1',
        'bp:ds:production:type:post',
      ],
    })

    const calls = mockedRevalidateTag.mock.calls.map((c) => c[0])
    expect(calls).toContain('bp:ds:production:doc:p1')
    expect(calls).toContain('bp:ds:production:type:post')
    expect(calls).toContain('bp:ds:production:_all')

    // Dedup: sync_tags overlap with derived tags should not double-fire.
    expect(new Set(calls).size).toBe(calls.length)
  })

  it('no sync_tags → canonical tags constructed from {dataset, type, doc_id}', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:_all')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(3)
  })

  it('regression guard: never emits legacy barkpark:doc:* or barkpark:type:* tags', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      sync_tags: ['bp:ds:production:doc:p1', 'bp:ds:production:type:post'],
    })

    // String input (historical footgun)
    revalidateBarkpark('p1')

    // Legacy shape still accepted — but only produces canonical tags (not the old literals).
    revalidateBarkpark({ _id: 'p2', _type: 'post', dataset: 'production' })

    const calls = mockedRevalidateTag.mock.calls.map((c) => String(c[0]))
    for (const tag of calls) {
      expect(tag.startsWith('barkpark:doc:')).toBe(false)
      expect(tag.startsWith('barkpark:type:')).toBe(false)
    }
  })

  it('legacy {_id, _type, dataset} → canonical bp:ds:* tags', () => {
    revalidateBarkpark({ _id: 'p1', _type: 'post', dataset: 'production' })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:_all')
  })

  it('legacy {ids, types, dataset} → fans out canonical tags', () => {
    revalidateBarkpark({ ids: ['a', 'b'], types: ['t1', 't2'], dataset: 'production' })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:a')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:b')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:t1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:t2')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:_all')
  })

  it('string input → no-op (no dataset context)', () => {
    revalidateBarkpark('p1')
    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it("{path: '/'} WITHOUT env → throws", () => {
    expect(() => revalidateBarkpark({ path: '/' })).toThrow(
      'Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1',
    )
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('path-gate throws BEFORE any tag invalidation (atomic error path)', () => {
    // Payload carries both sync_tags and a path, env flag unset. The throw must
    // fire before any revalidateTag side effect — no partial invalidation.
    expect(() =>
      revalidateBarkpark({
        type: 'post',
        doc_id: 'p1',
        dataset: 'production',
        sync_tags: ['bp:ds:production:doc:p1', 'bp:ds:production:type:post'],
        path: '/',
      }),
    ).toThrow('Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1')

    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it("{path: '/'} WITH BARKPARK_ALLOW_ALL_REVALIDATE=1 → revalidatePath called", () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark({ path: '/' })
    expect(mockedRevalidatePath).toHaveBeenCalledTimes(1)
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/')
  })

  it("{paths: ['/a','/b']} WITH env → two path calls", () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = 'true'
    revalidateBarkpark({ paths: ['/a', '/b'] })
    expect(mockedRevalidatePath).toHaveBeenCalledTimes(2)
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/a')
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/b')
  })

  it('{} → no-op, no throw', () => {
    expect(() => revalidateBarkpark({})).not.toThrow()
    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('no args → no-op, no throw', () => {
    expect(() => revalidateBarkpark()).not.toThrow()
    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  // ── s15: ingest the NEW workspace/project-scoped sync-tag shape ───────────

  it('NEW scoped sync_tags → forwarded verbatim to revalidateTag', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      workspace: 'acme',
      project: 'blog',
      sync_tags: [
        'bp:ws:acme:p:blog:ds:production:doc:p1',
        'bp:ws:acme:p:blog:ds:production:type:post',
      ],
    })

    const calls = mockedRevalidateTag.mock.calls.map((c) => String(c[0]))
    expect(calls).toContain('bp:ws:acme:p:blog:ds:production:doc:p1')
    expect(calls).toContain('bp:ws:acme:p:blog:ds:production:type:post')
    // Dedup holds across scoped + derived tags.
    expect(new Set(calls).size).toBe(calls.length)
  })

  it('NEW: no sync_tags, {workspace, project, dataset, type, doc_id} → scoped tags constructed', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      workspace: 'acme',
      project: 'blog',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:_all')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(3)
  })

  it('NEW: dispatcher _slug spellings accepted for scope', () => {
    revalidateBarkpark({
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      workspace_slug: 'acme',
      project_slug: 'blog',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:_all')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(3)
  })

  it('NEW: partial scope (workspace only, no project) → falls back to LEGACY flat tags', () => {
    revalidateBarkpark({
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      workspace: 'acme',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:_all')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(3)
  })

  it('LEGACY: no scope fields → flat bp:ds:* tags still constructed (back-compat)', () => {
    revalidateBarkpark({
      event: 'publish',
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:type:post')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ds:production:_all')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(3)
  })

  it('LEGACY sync_tags still forwarded verbatim alongside NEW capability', () => {
    revalidateBarkpark({
      type: 'post',
      doc_id: 'p1',
      dataset: 'production',
      sync_tags: ['bp:ds:production:doc:p1', 'bp:ds:production:type:post'],
    })

    const calls = mockedRevalidateTag.mock.calls.map((c) => String(c[0]))
    expect(calls).toContain('bp:ds:production:doc:p1')
    expect(calls).toContain('bp:ds:production:type:post')
    expect(new Set(calls).size).toBe(calls.length)
  })

  it('NEW: scoped ids/types fan out under the scoped prefix', () => {
    revalidateBarkpark({
      ids: ['a', 'b'],
      types: ['t1', 't2'],
      dataset: 'production',
      workspace: 'acme',
      project: 'blog',
    })

    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:doc:a')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:doc:b')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:type:t1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:type:t2')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('bp:ws:acme:p:blog:ds:production:_all')
  })
})
