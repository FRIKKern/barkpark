import { describe, it, expect } from 'vitest'
import { mapField } from '../src/codegen/map-field.js'
import type { RawField } from '../src/types.js'

function make(partial: Partial<RawField> & { type: string }): RawField {
  return { name: 'f', ...partial }
}

describe('mapField (strict)', () => {
  it('string', () => {
    expect(mapField(make({ type: 'string' }), false)).toEqual({
      name: 'f',
      tsType: 'string',
      kind: 'string',
      filterValueType: 'string',
      required: false,
    })
  })

  it('slug', () => {
    expect(mapField(make({ type: 'slug' }), false)).toEqual({
      name: 'f',
      tsType: "{ _type: 'slug'; current: string }",
      kind: 'slug',
      filterValueType: 'string',
      required: false,
    })
  })

  it('text', () => {
    expect(mapField(make({ type: 'text' }), false)).toEqual({
      name: 'f',
      tsType: 'string',
      kind: 'string',
      filterValueType: 'string',
      required: false,
    })
  })

  it('richText', () => {
    expect(mapField(make({ type: 'richText' }), false)).toEqual({
      name: 'f',
      tsType: 'unknown[]',
      kind: 'unfilterable',
      filterValueType: 'never',
      required: false,
    })
  })

  it('image', () => {
    expect(mapField(make({ type: 'image' }), false)).toEqual({
      name: 'f',
      tsType: "{ _type: 'image'; asset: { _ref: string } } | null",
      kind: 'unfilterable',
      filterValueType: 'never',
      required: false,
    })
  })

  it('boolean', () => {
    expect(mapField(make({ type: 'boolean' }), false)).toEqual({
      name: 'f',
      tsType: 'boolean',
      kind: 'boolean',
      filterValueType: 'boolean',
      required: false,
    })
  })

  it('datetime', () => {
    expect(mapField(make({ type: 'datetime' }), false)).toEqual({
      name: 'f',
      tsType: 'string',
      kind: 'date',
      filterValueType: 'string',
      required: false,
    })
  })

  it('color', () => {
    expect(mapField(make({ type: 'color' }), false)).toEqual({
      name: 'f',
      tsType: 'string',
      kind: 'string',
      filterValueType: 'string',
      required: false,
    })
  })

  it('select with options → union literal', () => {
    const r = mapField(make({ type: 'select', options: ['a', 'b'] }), false)
    expect(r.tsType).toBe('"a" | "b"')
    expect(r.kind).toBe('string')
    expect(r.filterValueType).toBe('"a" | "b"')
  })

  it('select without options → string', () => {
    const r = mapField(make({ type: 'select' }), false)
    expect(r.tsType).toBe('string')
    expect(r.kind).toBe('string')
  })

  it('reference', () => {
    expect(mapField(make({ type: 'reference' }), false)).toEqual({
      name: 'f',
      tsType: "{ _type: 'reference'; _ref: string }",
      kind: 'reference',
      filterValueType: 'string',
      required: false,
    })
  })

  it('array (no of) → unknown[]', () => {
    const r = mapField(make({ type: 'array' }), false)
    expect(r.tsType).toBe('unknown[]')
    expect(r.kind).toBe('unfilterable')
    expect(r.filterValueType).toBe('never')
  })

  it('unknown type strict → unknown/unfilterable', () => {
    const r = mapField(make({ type: 'weirdCustomType' }), false)
    expect(r.tsType).toBe('unknown')
    expect(r.kind).toBe('unfilterable')
    expect(r.filterValueType).toBe('never')
  })
})

describe('mapField (loose)', () => {
  it('unknown type loose → string/string', () => {
    const r = mapField(make({ type: 'weirdCustomType' }), true)
    expect(r.tsType).toBe('string')
    expect(r.kind).toBe('string')
    expect(r.filterValueType).toBe('string')
  })
})

describe('mapField required flag', () => {
  it('required: true → required === true', () => {
    expect(mapField(make({ type: 'string', required: true }), false).required).toBe(true)
  })

  it('"required?": true → required === true', () => {
    expect(mapField(make({ type: 'string', 'required?': true }), false).required).toBe(true)
  })

  it('absent → required === false', () => {
    expect(mapField(make({ type: 'string' }), false).required).toBe(false)
  })

  it('required: false → required === false', () => {
    expect(mapField(make({ type: 'string', required: false }), false).required).toBe(false)
  })

  it('"required?" takes precedence over required', () => {
    expect(
      mapField(make({ type: 'string', required: false, 'required?': true }), false).required,
    ).toBe(true)
  })
})
