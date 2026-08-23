// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { generateTypes, schemaEnvelopeSchema } from '../src/index'

/**
 * zod's envelope validator only asserts name/type on the TOP-LEVEL field of each
 * schema — its lazy body never recurses into `fields`/`of`. So a composite
 * sub-field missing `name` slips through validation and used to crash the mapper
 * with an opaque `TypeError: Cannot read properties of undefined (reading
 * 'localeCompare')` (only once 2+ subs make Array.sort invoke the comparator).
 * A hand-authored `--from` schema (or the CI drift-gate fixture) can hit this.
 */
describe('malformed nested descriptors — fail loud, never opaque', () => {
  function envelopeWith(fields: unknown[]) {
    return schemaEnvelopeSchema.parse({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [{ name: 'thing', fields }],
    })
  }

  it('a composite sub-field with no name throws a locatable error, not a TypeError', async () => {
    const envelope = envelopeWith([
      {
        name: 'price',
        type: 'composite',
        fields: [
          { name: 'currency', type: 'string' },
          { type: 'string' }, // <- no name
        ],
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(
      /composite field \("price"\) has a sub-field with no `name`/,
    )
    // and specifically NOT the old opaque crash
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.not.toThrow(/localeCompare/)
  })

  it('a NULL composite sub-field takes that same single error path', async () => {
    // The guard used to read `sub.name` inside its own test expression, so a
    // null sub threw `TypeError: Cannot read properties of null (reading
    // 'name')` before the guard could decide. Widened, not forked: same message.
    // Full matrix (undefined, array-nested, arrayOf-nested) in mapper-guards.test.ts.
    const envelope = envelopeWith([
      {
        name: 'price',
        type: 'composite',
        fields: [{ name: 'currency', type: 'string' }, null],
      },
    ])
    await expect(generateTypes(envelope, { dataset: 'x' })).rejects.toThrow(
      /composite field \("price"\) has a sub-field with no `name`/,
    )
  })

  it('localizedText.languages tolerates a non-string entry (no literal() crash)', async () => {
    const envelope = envelopeWith([
      { name: 'body', type: 'localizedText', languages: ['en', 123, 'nb'] },
    ])
    const out = await generateTypes(envelope, { dataset: 'x' })
    // the number is filtered out; the string keys survive
    expect(out).toMatch(/body\?:\s*Partial<Record<"en"\s*\|\s*"nb",\s*string>>/)
  })
})
