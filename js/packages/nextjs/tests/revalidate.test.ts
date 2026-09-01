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

  // `revalidateBarkpark` is documented to take a raw `await req.json()` body, so
  // every list arm must be Array.isArray-guarded — the reason spelled out in the
  // sync_tags comment in src/revalidate/index.ts. That ruling reached sync_tags,
  // ids and types; `paths` kept a bare truthy check, and a bare STRING is truthy
  // AND iterable. The cast below is the point: it is exactly the shape an
  // untyped webhook body has at runtime.
  const raw = (p: unknown) => p as Parameters<typeof revalidateBarkpark>[0]

  it('a STRING paths is not walked character by character', () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark(raw({ paths: '/blog' }))

    // The bug fired revalidatePath('/'), ('b'), ('l'), ('o'), ('g').
    expect(mockedRevalidatePath).not.toHaveBeenCalledWith('b')
    expect(mockedRevalidatePath).not.toHaveBeenCalledWith('l')
    expect(mockedRevalidatePath).not.toHaveBeenCalledWith('g')
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('a non-iterable paths (number, object) is ignored, not thrown on', () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    expect(() => revalidateBarkpark(raw({ paths: 42 }))).not.toThrow()
    expect(() => revalidateBarkpark(raw({ paths: { a: '/x' } }))).not.toThrow()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('non-string entries inside a real paths array are skipped, the rest still fire', () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark(raw({ paths: ['/a', 7, null, '', '/b'] }))
    expect(mockedRevalidatePath).toHaveBeenCalledTimes(2)
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/a')
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/b')
  })

  it('a non-string single path is ignored too', () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark(raw({ path: 42 }))
    revalidateBarkpark(raw({ path: '' }))
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('a malformed paths still trips the env gate — the refusal is not narrowed', () => {
    // The gate keys on PRESENCE, not shape, and must stay that way: a caller
    // without the opt-in gets the throw whatever they sent.
    expect(() => revalidateBarkpark(raw({ paths: '/blog' }))).toThrow(
      'Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1',
    )
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('a malformed paths does not suppress the tag fan-out beside it', () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark(
      raw({ dataset: 'production', type: 'post', doc_id: 'p1', paths: '/blog' }),
    )
    const calls = mockedRevalidateTag.mock.calls.map((c) => c[0])
    expect(calls).toContain('bp:ds:production:doc:p1')
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
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

  // revalidateBarkpark is public and documented to take a raw `await req.json()`
  // body, so a hand-built/legacy payload may carry a non-array sync_tags/ids/types.
  it('a non-array sync_tags does not throw (was TypeError: not iterable)', () => {
    expect(() =>
      revalidateBarkpark({ dataset: 'production', sync_tags: 123 as unknown as string[] }),
    ).not.toThrow()
  })

  it('a bare-string sync_tags is ignored, not iterated char-by-char into garbage tags', () => {
    revalidateBarkpark({
      dataset: 'production',
      sync_tags: 'bp:ds:production:doc:p1' as unknown as string[],
    })

    const calls = mockedRevalidateTag.mock.calls.map((c) => c[0])
    // The string was NOT walked character-by-character (no single-char tags).
    expect(calls).not.toContain('b')
    expect(calls).not.toContain('p')
    expect(calls).not.toContain(':')
    // The bogus full string is not added as a tag either (it wasn't an array).
    expect(calls).not.toContain('bp:ds:production:doc:p1')
    // The prefix-derived :_all tag from `dataset` still fires — the payload is
    // otherwise valid, only its sync_tags was malformed.
    expect(calls).toContain('bp:ds:production:_all')
  })

  it('a non-array ids/types is ignored, not iterated', () => {
    expect(() =>
      revalidateBarkpark({
        dataset: 'production',
        ids: 'p1' as unknown as string[],
        types: 42 as unknown as string[],
      }),
    ).not.toThrow()

    const calls = mockedRevalidateTag.mock.calls.map((c) => c[0])
    // 'p1' must not be char-iterated into bp:ds:production:doc:p / :doc:1.
    expect(calls).not.toContain('bp:ds:production:doc:p')
    expect(calls).not.toContain('bp:ds:production:doc:1')
  })
})
