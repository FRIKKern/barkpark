import { describe, it, expect } from 'vitest'
import { createDocsBuilder, buildQueryString, makeFilterExpression } from '../src/filter-builder'
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
      .hasStrong('tags', 'search:40')
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
      { field: 'tags', op: 'hasStrong', value: 'search:40' },
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

  it('in()/nin() reject an empty candidate list (match-nothing is almost always a bug)', () => {
    // `filter[f][in]=` matches nothing — fail closed like the peer array guard.
    expect(() => createDocsBuilder(async () => []).in('tag', [])).toThrow(BarkparkValidationError)
    expect(() => createDocsBuilder(async () => []).nin('tag', [])).toThrow(BarkparkValidationError)
    // raw .where(f, 'in', []) is covered by the same makeFilterExpression guard
    expect(() => makeFilterExpression('tag', 'in', [])).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('tag', 'nin', [])).toThrow(BarkparkValidationError)
  })

  it('in()/nin() fail closed when a candidate value contains a comma', () => {
    // The wire format joins candidates with ',' and the server splits on it, so
    // `['A,B']` would silently become two candidates (A OR B) — throw instead.
    expect(() => createDocsBuilder(async () => []).in('sku', ['A,B'])).toThrow(
      /comma/,
    )
    expect(() => createDocsBuilder(async () => []).in('sku', ['A,B'])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createDocsBuilder(async () => []).nin('sku', ['A,B'])).toThrow(
      /comma/,
    )
    expect(() => createDocsBuilder(async () => []).nin('sku', ['A,B'])).toThrow(
      BarkparkValidationError,
    )
  })

  it('hasStrong() passes the scalar `<tag>:<min_strength>` value through unguarded', () => {
    // hasStrong is a scalar op (NOT in ARRAY_OPS), so the value-guard dispatch on
    // ARRAY_OPS membership lets the string through with zero new guard code — the
    // colon-bearing `'search:40'` is a plain scalar, not an array.
    expect(makeFilterExpression('tags', 'hasStrong', 'search:40')).toEqual({
      field: 'tags',
      op: 'hasStrong',
      value: 'search:40',
    })
  })

  it('hasStrong() rejects an array value (scalar-only, like has)', () => {
    // Same guard that fails `has('f', [...])`: a non-array op with an array value.
    expect(() => makeFilterExpression('tags', 'hasStrong', ['a', 'b'] as any)).toThrow(
      BarkparkValidationError,
    )
  })

  it('buildQueryString encodes hasStrong in Phoenix nested-map shape', () => {
    // filter[tags][hasStrong]=search:40 — the server splits on the LAST colon.
    const qs = buildQueryString({
      filters: [{ field: 'tags', op: 'hasStrong', value: 'search:40' }],
    })
    expect(decodeURIComponent(qs)).toContain('filter[tags][hasStrong]=search:40')
  })

  it('in() with plain values still encodes comma-joined (no regression)', async () => {
    let captured: any
    await createDocsBuilder(async (s) => {
      captured = s
      return []
    })
      .in('sku', ['A', 'B'])
      .find()
    expect(buildQueryString(captured)).toContain('filter%5Bsku%5D%5Bin%5D=A%2CB')
  })

  it('in() with Date values is exempt from the comma guard (ISO strings have no comma)', () => {
    expect(() =>
      createDocsBuilder(async () => []).in('date', [new Date('2026-07-01T00:00:00.000Z')]),
    ).not.toThrow()
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

  it('expand()/select() reject a comma inside a field name (would corrupt the projection)', () => {
    // A field carrying the ',' delimiter would silently split into multiple
    // fields server-side; reject it so the caller passes an array instead.
    expect(() => createDocsBuilder(async () => []).expand('author,secret')).toThrow(
      BarkparkValidationError,
    )
    expect(() => createDocsBuilder(async () => []).expand(['ok', 'a,b'])).toThrow(
      BarkparkValidationError,
    )
    expect(() => createDocsBuilder(async () => []).select('title,internal')).toThrow(
      BarkparkValidationError,
    )
    expect(() => createDocsBuilder(async () => []).select(['title', 'a,b'])).toThrow(
      BarkparkValidationError,
    )
  })

  it('findOne() sets limit=1 and returns first doc or null', async () => {
    const b1 = createDocsBuilder(async () => [{ _id: 'x', _type: 'post' } as any])
    expect(await b1.findOne()).toMatchObject({ _id: 'x' })
    const b2 = createDocsBuilder(async () => [])
    expect(await b2.findOne()).toBeNull()
  })

  it('findOne() does not leak limit=1 into a concurrent find() (no shared-state mutation)', async () => {
    // Each executor call records the query string it would send, THEN yields a
    // microtask — so both concurrent calls read `state` before either resolves.
    // Fails on the old mutate/try/finally findOne (find() sees limit=1).
    const urls: string[] = []
    const b = createDocsBuilder(async (state) => {
      urls.push(buildQueryString(state))
      await Promise.resolve()
      return []
    })
    b.limit(50)
    await Promise.all([b.findOne(), b.find()])
    // findOne carries its own derived limit=1; find() must carry the builder's 50.
    expect(urls).toContain('limit=50')
    expect(urls).toContain('limit=1')
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
    // hasMore is REQUIRED on QueryPage: a page that cannot say whether more
    // rows exist is not a page. nextOffset stays optional -- it is absent when
    // there is no next page.
    const page = {
      documents: [{ _id: 'p1' } as any],
      total: 9,
      count: 1,
      limit: 20,
      offset: 0,
      hasMore: true,
      nextOffset: 20,
    }
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
    // ... including nested dot-paths (the server orders them like top-level) ...
    expect(() => b.order('price.amount:asc')).not.toThrow()
    expect(() => b.order('meta.seo.score:desc')).not.toThrow()
    // ... but the shape is still validated
    expect(() => b.order('title' as any)).toThrow(BarkparkValidationError)
    expect(() => b.order('title:up' as any)).toThrow(BarkparkValidationError)
    expect(() => b.order('price.:asc' as any)).toThrow(BarkparkValidationError) // trailing dot
    expect(() => b.order('.price:asc' as any)).toThrow(BarkparkValidationError) // leading dot
  })

  it('requires array for in/nin and rejects array elsewhere', () => {
    expect(() => makeFilterExpression('tags', 'in', 'x' as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('tags', 'nin', 'x' as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('title', 'eq', ['x'] as any)).toThrow(BarkparkValidationError)
    expect(() => makeFilterExpression('tags', 'nin', ['x', 'y'])).not.toThrow()
  })

  it('rejects a non-Date object value on a scalar op (would serialize to [object Object])', () => {
    expect(() => makeFilterExpression('author', 'eq', { _ref: 'x' } as any)).toThrow(
      BarkparkValidationError,
    )
    expect(() => makeFilterExpression('author', 'eq', { _ref: 'x' } as any)).toThrow(
      /scalar value/,
    )
    // Dates and primitives on scalar ops are still accepted.
    expect(() => makeFilterExpression('publishedAt', 'gt', new Date())).not.toThrow()
    expect(() => makeFilterExpression('title', 'eq', 'hello')).not.toThrow()
    expect(() => makeFilterExpression('rank', 'gte', 5)).not.toThrow()
    expect(() => makeFilterExpression('active', 'eq', true)).not.toThrow()
    // null is a valid absence check, not an object rejection.
    expect(() => makeFilterExpression('author', 'eq', null)).not.toThrow()
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

  it('buildQueryString maps eq/neq null to the `is` op (IS NULL / IS NOT NULL)', () => {
    const isNull = buildQueryString({ filters: [{ field: 'category', op: 'eq', value: null }] })
    // filter[category][is]=null — NOT filter[category][eq]= (which would match "")
    expect(isNull).toBe('filter%5Bcategory%5D%5Bis%5D=null')

    const isNotNull = buildQueryString({ filters: [{ field: 'category', op: 'neq', value: null }] })
    expect(isNotNull).toBe('filter%5Bcategory%5D%5Bis%5D=notnull')
  })

  it('buildQueryString ISO-normalizes a Date value (not a locale string)', () => {
    const qs = buildQueryString({
      filters: [{ field: '_createdAt', op: 'gt', value: new Date('2026-07-01T00:00:00Z') }],
    })
    // decode so the ISO colons (%3A) don't obscure the assertion
    expect(decodeURIComponent(qs)).toContain('2026-07-01T00:00:00.000Z')
    // never the locale form (Date.prototype.toString → 'Thu Jul 01 2026 …')
    expect(qs).not.toContain('Jul')
  })

  it('.gt(field, Date) encodes the ISO timestamp end-to-end', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b.gt('_createdAt', new Date('2026-07-01T00:00:00Z')).find()
    expect(decodeURIComponent(buildQueryString(captured))).toContain('2026-07-01T00:00:00.000Z')
  })

  it('startsWith/endsWith — builder methods + query encoding', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b.startsWith('slug', '2024-').endsWith('file', '.pdf').find()
    expect(captured.filters).toEqual([
      { field: 'slug', op: 'startsWith', value: '2024-' },
      { field: 'file', op: 'endsWith', value: '.pdf' },
    ])

    expect(
      buildQueryString({ filters: [{ field: 'slug', op: 'startsWith', value: '2024-' }] }),
    ).toBe('filter%5Bslug%5D%5BstartsWith%5D=2024-')
    expect(buildQueryString({ filters: [{ field: 'file', op: 'endsWith', value: '.pdf' }] })).toBe(
      'filter%5Bfile%5D%5BendsWith%5D=.pdf',
    )
  })

  it('order chaining appends sort keys (multi-field sort)', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b.order('status:asc').order('title:desc').find()
    // appended, not replaced
    expect(captured.order).toBe('status:asc,title:desc')
    expect(buildQueryString({ filters: [], order: 'status:asc,title:desc' })).toContain(
      'order=status%3Aasc%2Ctitle%3Adesc',
    )
  })

  it('select builds a `fields` projection param (array or single)', async () => {
    let captured: any
    const b = createDocsBuilder(async (state) => {
      captured = state
      return []
    })
    await b.select(['title', 'slug']).find()
    expect(captured.select).toBe('title,slug')
    expect(buildQueryString({ filters: [], select: 'title,slug' })).toContain('fields=title%2Cslug')
    expect(buildQueryString({ filters: [], select: 'title' })).toContain('fields=title')
  })

  it('select throws on an empty field list', () => {
    const b = createDocsBuilder(async () => [])
    expect(() => b.select([])).toThrow(BarkparkValidationError)
    expect(() => b.select('  ')).toThrow(BarkparkValidationError)
  })
})
