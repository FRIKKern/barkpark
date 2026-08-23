// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { generateTypes } from '../src/generate'

/**
 * cca-backlog-reserved-system-field-names: three fixture shapes used to emit
 * TypeScript that failed at the CONSUMER's tsc instead of failing codegen —
 * duplicate schema names (two identical `export interface Post` + a duplicate
 * BarkparkTypeMap key), a field named `_type` (declared twice beside the
 * pinned literal), and a field named `_id` (redeclares the inherited `string`
 * incompatibly). All three are server-gated (content/envelope.ex @reserved
 * rejects them on the live API) and reachable only via a hand-authored --from
 * fixture — hence belt-and-suspenders: fail LOUD with a locatable message
 * before writing a byte.
 */

const env = (schemas: object[]) => ({
  _schemaVersion: 1,
  datasetSchemaHash: 'h',
  schemas: schemas as never,
})

describe('generateTypes — reserved names and duplicates fail loud, never emit invalid TS', () => {
  it('duplicate schema names name BOTH positions and the colliding interface', async () => {
    await expect(
      generateTypes(env([{ name: 'post', fields: [] }, { name: 'post', fields: [] }])),
    ).rejects.toThrow('schema #0 ("post") and schema #1 ("post") both become interface "Post"')
  })

  it('names that collide only AFTER identifier sanitising are caught too', async () => {
    await expect(
      generateTypes(env([{ name: 'blog-post', fields: [] }, { name: 'blog_post', fields: [] }])),
    ).rejects.toThrow('both become interface "Blog_post"')
  })

  it('a field named _type is refused with the schema and field position', async () => {
    await expect(
      generateTypes(
        env([{ name: 'post', fields: [{ name: '_type', type: 'string', required: true }] }]),
      ),
    ).rejects.toThrow('schema "post" field #0 is named "_type", a server-reserved system key')
  })

  it('a field named _id is refused the same way', async () => {
    await expect(
      generateTypes(
        env([
          {
            name: 'post',
            fields: [
              { name: 'title', type: 'string', required: true },
              { name: '_id', type: 'number', required: true },
            ],
          },
        ]),
      ),
    ).rejects.toThrow('schema "post" field #1 is named "_id", a server-reserved system key')
  })

  it('a legitimate underscore-prefixed field that is NOT reserved still generates', async () => {
    const out = await generateTypes(
      env([{ name: 'post', fields: [{ name: '_meta', type: 'string', required: true }] }]),
    )
    expect(out).toContain('_meta: string')
  })
})
