import { describe, it, expect } from 'vitest'
import {
  createDocsBuilder,
  buildQueryString,
  makeFilterExpression,
} from '../src/filter-builder'
import { BarkparkValidationError } from '../src/errors'

describe('filter-builder', () => {
  it('chains where/order/limit/offset fluently', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b.where('title', 'eq', 'Hello').order('_updatedAt:desc').limit(10).offset(5).find()
    expect(captured.filters).toEqual([{ field: 'title', op: 'eq', value: 'Hello' }])
    expect(captured.order).toBe('_updatedAt:desc')
    expect(captured.limit).toBe(10)
    expect(captured.offset).toBe(5)
  })

  it('semantic sugar (eq/neq/in/nin/has/contains/gt/gte/lt/lte) maps to the right ops', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b
      .eq('status', 'published')
      .neq('status', 'archived')
      .in('tag', ['a', 'b'])
      .nin('tag', ['x', 'y'])
      .has('tags', 'tag-x')
      .contains('title', 'hello')
      .gt('rank', 5)
      .gte('score', 1)
      .lt('rank', 100)
      .lte('score', 9)
      .find()
    expect(captured.filters).toEqual([
      { field: 'status', op: 'eq', value: 'published' },
      { field: 'status', op: 'neq', value: 'archived' },
      { field: 'tag', op: 'in', value: ['a', 'b'] },
      { field: 'tag', op: 'nin', value: ['x', 'y'] },
      { field: 'tags', op: 'has', value: 'tag-x' },
      { field: 'title', op: 'contains', value: 'hello' },
      { field: 'rank', op: 'gt', value: 5 },
      { field: 'score', op: 'gte', value: 1 },
      { field: 'rank', op: 'lt', value: 100 },
      { field: 'score', op: 'lte', value: 9 },
    ])
  })

  it('sugar inherits where() validation (in requires an array)', () => {
    const b = createDocsBuilder(async () => [])
    expect(() => b.in('tag', 'x' as any)).toThrow(BarkparkValidationError)
  })

  it('expand() inlines reference fields (single + array) into the query string', async () => {
    let single: any
    await createDocsBuilder(async (s) => {
      single = s
      return []
    })
      .expand('author')
      .find()
    expect(single.expand).toBe('author')
    expect(buildQueryString(single)).toContain('expand=author')

    let multi: any
    await createDocsBuilder(async (s) => {
      multi = s
      return []
    })
      .expand(['author', 'tags'])
      .find()
    expect(multi.expand).toBe('author,tags')
    expect(buildQueryString(multi)).toContain('expand=author')
  })

  it('expand() rejects an empty field set', () => {
    const b = createDocsBuilder(async () => [])
    expect(() => b.expand([])).toThrow(BarkparkValidationError)
    expect(() => b.expand('   ')).toThrow(BarkparkValidationError)
  })

  it('findOne() sets limit=1 and returns first doc or null', async () => {
    const b1 = createDocsBuilder(async () => [{ _id: 'x', _type: 'post' } as any])
    expect(await b1.findOne()).toMatchObject({ _id: 'x' })
    const b2 = createDocsBuilder(async () => [])
    expect(await b2.findOne()).toBeNull()
  })

  it('count() calls the count executor; throws when none was provided', async () => {
    let seenState: any
    const b1 = createDocsBuilder(
      async () => [],
      async (state) => {
        seenState = state
        return 7
      },
    )
    expect(await b1.eq('status', 'published').count()).toBe(7)
    expect(seenState.filters).toEqual([{ field: 'status', op: 'eq', value: 'published' }])

    const b2 = createDocsBuilder(async () => [])
    await expect(b2.count()).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('findPage() calls the page executor with the state; throws when none was provided', async () => {
    let seenState: any
    const page = { documents: [{ _id: 'p1' } as any], total: 9, count: 1, limit: 20, offset: 0 }
    const b1 = createDocsBuilder(
      async () => [],
      async () => 0,
      async (state) => {
        seenState = state
        return page
      },
    )
    expect(await b1.eq('status', 'published').limit(20).findPage()).toEqual(page)
    expect(seenState.filters).toEqual([{ field: 'status', op: 'eq', value: 'published' }])
    expect(seenState.limit).toBe(20)

    const b2 = createDocsBuilder(async () => [])
    await expect(b2.findPage()).rejects.toBeInstanceOf(BarkparkValidationError)
  })

  it('rejects invalid op', () => {
    expect(() => makeFilterExpression('title', 'like' as any, 'x')).toThrow(BarkparkValidationError)
  })

  it('error messages are actionable — they name the valid choices', () => {
    // unknown op lists the allowed ops; bad order spec names the expected shape
    expect(() => makeFilterExpression('title', 'like' as any, 'x')).toThrow(/expected one of .*eq/)
    const b = createDocsBuilder(async () => [])
    expect(() => b.order('title:up' as any)).toThrow(/<field>:asc\|desc/)
  })

  it('order accepts any field, not just timestamps', () => {
    const b = createDocsBuilder(async () => [])
    // content / promoted fields are valid now (server resolves them) ...
    expect(() => b.order('title:asc')).not.toThrow()
    expect(() => b.order('publishedAt:desc')).not.toThrow()
    expect(() => b.order('_createdAt:asc')).not.toThrow()
    // ... but the shape is still validated
    expect(() => b.order('title' as any)).toThrow(BarkparkValidationError)
    expect(() => b.order('title:up' as any)).toThrow(BarkparkValidationError)
  })

  it('requires array for in/nin and rejects array elsewhere', () => {
    expect(() => makeFilterExpression('tags', 'in', 'x' as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('tags', 'nin', 'x' as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('title', 'eq', ['x'] as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('tags', 'nin', ['x', 'y'])).not.toThrow()
  })

  it('rejects invalid order / limit / offset', () => {
    const b = createDocsBuilder(async () => [])
    expect(() => b.order('title:sideways' as any)).toThrow(BarkparkValidationError)
    expect(() => b.limit(0)).toThrow(BarkparkValidationError)
    expect(() => b.offset(-1)).toThrow(BarkparkValidationError)
  })

  it('buildQueryString encodes filters+order+limit+offset in Phoenix nested-map shape', () => {
    const qs = buildQueryString({
      filters: [{ field: 'title', op: 'eq', value: 'Hello World' }],
      order: '_updatedAt:desc',
      limit: 10,
      offset: 0,
    })
    // URL-encoded form of filter[title][eq]=Hello+World
    expect(qs).toContain('filter%5Btitle%5D%5Beq%5D=Hello+World')
    expect(qs).toContain('order=_updatedAt%3Adesc')
    expect(qs).toContain('limit=10')
    expect(qs).toContain('offset=0')
  })

  it('buildQueryString joins in-values with comma (Phoenix CSV form)', () => {
    const qs = buildQueryString({
      filters: [{ field: 'status', op: 'in', value: ['draft', 'published'] }],
    })
    expect(qs).toContain('filter%5Bstatus%5D%5Bin%5D=draft%2Cpublished')
  })
})
