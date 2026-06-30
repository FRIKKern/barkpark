// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect } from 'vitest'
import { generateTypes } from '../src/generate'
import type { FieldDef } from '../src/types'

// Emit the generated module for a single document type with one field, so a test
// can assert that field's mapped member line. generateTypes runs prettier, so
// assertions match the formatted member (`name: Type` / `name?: Type`).
async function genField(field: FieldDef): Promise<string> {
  return generateTypes({
    _schemaVersion: 1,
    datasetSchemaHash: 'h',
    schemas: [{ name: 'thing', fields: [field] }],
  })
}

describe('generateTypes — field-type mappings', () => {
  it('string / text / color / datetime → string', async () => {
    for (const type of ['string', 'text', 'color', 'datetime']) {
      expect(await genField({ name: 'f', type, required: true })).toContain('f: string')
    }
  })

  it('number → number, boolean → boolean', async () => {
    expect(await genField({ name: 'n', type: 'number', required: true })).toContain('n: number')
    expect(await genField({ name: 'b', type: 'boolean', required: true })).toContain('b: boolean')
  })

  it('slug / image / reference → the value-type aliases', async () => {
    expect(await genField({ name: 's', type: 'slug', required: true })).toContain('s: BarkparkSlug')
    expect(await genField({ name: 'i', type: 'image', required: true })).toContain(
      'i: BarkparkImage',
    )
    expect(await genField({ name: 'r', type: 'reference', required: true })).toContain(
      'r: BarkparkReference',
    )
  })

  it('select → sorted union of string literals; no options → string', async () => {
    const out = await genField({
      name: 'status',
      type: 'select',
      required: true,
      options: ['published', 'draft'],
    })
    expect(out).toContain("status: 'draft' | 'published'")
    expect(await genField({ name: 'e', type: 'select', required: true })).toContain('e: string')
  })

  it('codelist → string (registry-backed, no inline union)', async () => {
    expect(await genField({ name: 'c', type: 'codelist', required: true })).toContain('c: string')
  })

  it('array (v1, of=[descriptor]) → Array<member>', async () => {
    const out = await genField({
      name: 'tags',
      type: 'array',
      required: true,
      of: [{ name: '_', type: 'string' }],
    })
    expect(out).toContain('tags: Array<string>')
  })

  it('arrayOf (v2, of=descriptor) → Array<member>', async () => {
    const out = await genField({
      name: 'tags',
      type: 'arrayOf',
      required: true,
      of: { name: '_', type: 'string' },
    })
    expect(out).toContain('tags: Array<string>')
  })

  it('composite → inline object recursing on subfields', async () => {
    const out = await genField({
      name: 'price',
      type: 'composite',
      required: true,
      fields: [
        { name: 'amount', type: 'number', required: true },
        { name: 'currency', type: 'string' },
      ],
    })
    expect(out).toContain('amount: number')
    expect(out).toContain('currency?: string')
  })

  it('object → Record<string, unknown>', async () => {
    expect(await genField({ name: 'o', type: 'object', required: true })).toContain(
      'o: Record<string, unknown>',
    )
  })

  it('richText → unknown', async () => {
    expect(await genField({ name: 'body', type: 'richText', required: true })).toContain(
      'body: unknown',
    )
  })

  it('localizedText → Partial<Record<sorted-langs, string>>', async () => {
    const out = await genField({
      name: 't',
      type: 'localizedText',
      required: true,
      languages: ['nob', 'eng'],
    })
    expect(out).toContain("t: Partial<Record<'eng' | 'nob', string>>")
  })

  it('an unrecognized type → unknown (surfaced, never silently dropped)', async () => {
    expect(await genField({ name: 'x', type: 'geopoint', required: true })).toContain('x: unknown')
  })

  it('optionality: required → no `?`; absent/`required?` honored both ways', async () => {
    expect(await genField({ name: 'opt', type: 'string' })).toContain('opt?: string')
    expect(await genField({ name: 'req', type: 'string', required: true })).toContain('req: string')
    // the live API spells the flag `required?` (literal key)
    expect(await genField({ name: 'rq', type: 'string', 'required?': true })).toContain(
      'rq: string',
    )
  })

  it('emits one interface per schema extending BarkparkSystemFields', async () => {
    const out = await genField({ name: 'title', type: 'string', required: true })
    expect(out).toContain('export interface Thing extends BarkparkSystemFields')
  })
})
