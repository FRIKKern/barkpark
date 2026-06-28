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

  it('semantic sugar (eq/in/contains/gt/gte/lt/lte) maps to the right ops', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b
      .eq('status', 'published')
      .in('tag', ['a', 'b'])
      .contains('title', 'hello')
      .gt('rank', 5)
      .gte('score', 1)
      .lt('rank', 100)
      .lte('score', 9)
      .find()
    expect(captured.filters).toEqual([
      { field: 'status', op: 'eq', value: 'published' },
      { field: 'tag', op: 'in', value: ['a', 'b'] },
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

  it('findOne() sets limit=1 and returns first doc or null', async () => {
    const b1 = createDocsBuilder(async () => [{ _id: 'x', _type: 'post' } as any])
    expect(await b1.findOne()).toMatchObject({ _id: 'x' })
    const b2 = createDocsBuilder(async () => [])
    expect(await b2.findOne()).toBeNull()
  })

  it('rejects invalid op', () => {
    expect(() => makeFilterExpression('title', 'like' as any, 'x')).toThrow(BarkparkValidationError)
  })

  it('requires array for in and rejects array elsewhere', () => {
    expect(() => makeFilterExpression('tags', 'in', 'x' as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('title', 'eq', ['x'] as any)).toThrow(BarkparkValidationError)
  })

  it('rejects invalid order / limit / offset', () => {
    const b = createDocsBuilder(async () => [])
    expect(() => b.order('title:asc' as any)).toThrow(BarkparkValidationError)
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
