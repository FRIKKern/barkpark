import { describe, it, expect } from 'vitest'
import { emitZodForSchema } from '../src/codegen/zod.js'
import type { RawSchema } from '../src/types.js'

function schema(fields: RawSchema['fields'], name = 'thing'): RawSchema {
  return { name, fields }
}

describe('emitZodForSchema', () => {
  it('string field → z.object({ fieldName: z.string() ...', () => {
    const out = emitZodForSchema(
      schema([{ name: 'title', type: 'string', required: true }]),
      false,
    )
    expect(out).toContain('z.object({')
    expect(out).toContain('title: z.string()')
  })

  it('select with options → z.enum([...] as const)', () => {
    const out = emitZodForSchema(
      schema([{ name: 'role', type: 'select', options: ['a', 'b'], required: true }]),
      false,
    )
    expect(out).toContain('z.enum(["a", "b"] as const)')
  })

  it('reference → strict object with _type/_ref', () => {
    const out = emitZodForSchema(
      schema([{ name: 'author', type: 'reference', required: true }]),
      false,
    )
    expect(out).toContain(
      'z.object({ _type: z.literal("reference"), _ref: z.string() }).strict()',
    )
  })

  it('strict mode → ends with }).strict();', () => {
    const out = emitZodForSchema(
      schema([{ name: 'title', type: 'string', required: true }]),
      false,
    )
    expect(out.trim().endsWith('}).strict();')).toBe(true)
  })

  it('loose mode → ends with }).passthrough();', () => {
    const out = emitZodForSchema(
      schema([{ name: 'title', type: 'string', required: true }]),
      true,
    )
    expect(out.trim().endsWith('}).passthrough();')).toBe(true)
  })

  it('required field is NOT .optional()', () => {
    const out = emitZodForSchema(
      schema([{ name: 'title', type: 'string', required: true }]),
      false,
    )
    expect(out).not.toMatch(/title: z\.string\(\)\.optional\(\)/)
    expect(out).toMatch(/title: z\.string\(\),/)
  })

  it('non-required field IS .optional()', () => {
    const out = emitZodForSchema(
      schema([{ name: 'title', type: 'string' }]),
      false,
    )
    expect(out).toMatch(/title: z\.string\(\)\.optional\(\),/)
  })

  it('system fields (_id, _type, _createdAt, etc.) are NOT emitted', () => {
    const out = emitZodForSchema(
      schema([
        { name: '_id', type: 'string', required: true },
        { name: '_type', type: 'string', required: true },
        { name: '_draft', type: 'boolean', required: true },
        { name: '_publishedId', type: 'string', required: true },
        { name: '_createdAt', type: 'datetime', required: true },
        { name: '_updatedAt', type: 'datetime', required: true },
        { name: 'title', type: 'string', required: true },
      ]),
      false,
    )
    expect(out).not.toContain('_id:')
    expect(out).not.toContain('_type:')
    expect(out).not.toContain('_draft:')
    expect(out).not.toContain('_publishedId:')
    expect(out).not.toContain('_createdAt:')
    expect(out).not.toContain('_updatedAt:')
    expect(out).toContain('title:')
  })
})
