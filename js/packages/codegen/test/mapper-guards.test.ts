// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { generateTypes, schemaEnvelopeSchema } from '../src/index'

/**
 * Two crash classes the mapper used to hit on malformed-but-validated input.
 *
 * BUG A — a NULL/UNDEFINED composite sub-field. zod's `fieldSchema` is
 * `.object({name,type}).passthrough()`, so a composite's nested `fields` array is
 * an unvalidated passthrough key: `safeParse` returns success for
 * `{type:'composite',fields:[{…},null]}` even though a null TOP-LEVEL field is
 * rejected. The nameless-sub guard read `typeof sub.name` inside its own test
 * expression, so the property access threw first —
 * `TypeError: Cannot read properties of null (reading 'name')` — the exact opaque
 * crash that guard exists to eliminate. Also reachable one level down, nested
 * under `array` (`of: [...]`) and `arrayOf` (`of: {...}`).
 *
 * BUG B — an EMPTY schema name. `pascalCase('')` is `''` and the envelope's
 * `name: z.string()` carries no `.min(1)`, so the emitter produced
 * `export interface  extends BarkparkSystemFields {` and died downstream in
 * prettier with `SyntaxError: Declaration or statement expected. (48:1)` —
 * a location in generated output, pointing at nothing the author wrote.
 */
describe('mapper guards — malformed input fails loud and locatably', () => {
  function envelopeWith(fields: unknown[]) {
    return schemaEnvelopeSchema.parse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [{ name: 'thing', fields }],
    })
  }

  const LOCATABLE = /composite field \("price"\) has a sub-field with no `name`/

  it('validation really does let a null composite sub-field through (the guard is the only defense)', () => {
    const parsed = schemaEnvelopeSchema.safeParse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [
        { name: 'thing', fields: [{ name: 'price', type: 'composite', fields: [null] }] },
      ],
    })
    expect(parsed.success).toBe(true)
    // …while a null TOP-LEVEL field is rejected: the gap is exactly one level deep.
    const topLevel = schemaEnvelopeSchema.safeParse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [{ name: 'thing', fields: [null] }],
    })
    expect(topLevel.success).toBe(false)
  })

  it('a null composite sub-field throws the locatable error, not a TypeError', async () => {
    const envelope = envelopeWith([
      {
        name: 'price',
        type: 'composite',
        fields: [{ name: 'currency', type: 'string' }, null],
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(LOCATABLE)
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(
      /Cannot read properties/,
    )
  })

  it('an undefined composite sub-field throws the locatable error, not a TypeError', async () => {
    const envelope = envelopeWith([
      {
        name: 'price',
        type: 'composite',
        fields: [{ name: 'currency', type: 'string' }, undefined],
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(LOCATABLE)
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(
      /Cannot read properties/,
    )
  })

  it('a null sub-field nested under `array` (schema v1) throws the locatable error', async () => {
    const envelope = envelopeWith([
      {
        name: 'lines',
        type: 'array',
        of: [
          {
            name: 'price',
            type: 'composite',
            fields: [{ name: 'currency', type: 'string' }, null],
          },
        ],
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(LOCATABLE)
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(
      /Cannot read properties/,
    )
  })

  it('a null sub-field nested under `arrayOf` (schema v2) throws the locatable error', async () => {
    const envelope = envelopeWith([
      {
        name: 'lines',
        type: 'arrayOf',
        of: {
          name: 'price',
          type: 'composite',
          fields: [{ name: 'currency', type: 'string' }, null],
        },
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(LOCATABLE)
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(
      /Cannot read properties/,
    )
  })

  it('a primitive composite sub-field keeps hitting the SAME single error path', async () => {
    for (const sub of [123, 'currency']) {
      const envelope = envelopeWith([
        {
          name: 'price',
          type: 'composite',
          fields: [{ name: 'currency', type: 'string' }, sub],
        },
      ])
      await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(LOCATABLE)
    }
  })

  it('an empty schema name throws a locatable error naming its position, not a prettier SyntaxError', async () => {
    const envelope = schemaEnvelopeSchema.parse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [{ name: 'post', fields: [] }, { name: '', fields: [] }],
    })
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(
      /codegen: schema #1 has an empty `name`/,
    )
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(/SyntaxError/)
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(
      /Declaration or statement expected/,
    )
  })

  it('does not sanitize an empty name into an invented interface', async () => {
    const envelope = schemaEnvelopeSchema.parse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [{ name: '', fields: [] }],
    })
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(/empty `name`/)
  })

  // The degradations below are DELIBERATE (re-proved this wave) — they must stay
  // soft while the two crash classes above stay loud.
  it('keeps the deliberate soft degradations intact', async () => {
    const envelope = schemaEnvelopeSchema.parse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [
        {
          name: 'thing',
          fields: [
            { name: 'emptyArray', type: 'array', of: [] },
            { name: 'nullOf', type: 'arrayOf', of: null },
            { name: 'nullElement', type: 'array', of: [null] },
            { name: 'noOptions', type: 'select', options: [] },
            { name: 'fieldless', type: 'composite', fields: [] },
          ],
        },
      ],
    })
    const out = await generateTypes(envelope, { dataset: 'x' })
    expect(out).toMatch(/emptyArray\?:\s*Array<unknown>/)
    expect(out).toMatch(/nullOf\?:\s*Array<unknown>/)
    expect(out).toMatch(/nullElement\?:\s*Array<unknown>/)
    expect(out).toMatch(/noOptions\?:\s*string/)
    expect(out).toMatch(/fieldless\?:\s*Record<string,\s*unknown>/)
  })

  it('an empty schema list still emits an empty map and a `never` union', async () => {
    const out = await generateTypes(
      schemaEnvelopeSchema.parse({ _schemaVersion: 1, datasetSchemaHash: 'h', schemas: [] }),
      { dataset: 'x' },
    )
    expect(out).toMatch(/export type BarkparkTypeMap = \{\}/)
    expect(out).toMatch(/export type BarkparkAnyDocument = never/)
  })
})
