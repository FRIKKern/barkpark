// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { RawSchema, RawSchemaDoc } from '../types.js'
import { mapField } from './map-field.js'
import { CODEGEN_VERSION, EMPTY_MAP_SENTINEL, PRELUDE, TYPED_CLIENT_RUNTIME } from './prelude.js'
import { emitZodForSchema, emitZodPrelude } from './zod.js'

/**
 * Options accepted by `emit`.
 */
export interface EmitOptions {
  /** Loose mode: unknown field types degrade to `string`, Zod uses `.passthrough()`. */
  loose: boolean
  /** Full hex schema-hash, stamped into the generated header. */
  schemaHash: string
  /** Optional source label, defaults to `/v1/schemas/production`. */
  source?: string
}

/**
 * Render the Barkpark generated-types module as a single string. Port of
 * Spike B `codegen.ts` L83–253 with three v0.1 additions:
 *
 * 1. **Zod input schemas** emitted per document type (see `./zod`).
 * 2. **Empty-map sentinel** on `DocumentType` so a missing run of
 *    `barkpark codegen` surfaces a pointed compile error.
 * 3. **`CollectionMap` / `CollectionSlug` / `BarkparkDocument`** aliases
 *    for ergonomic call-sites that don't care about the filter path.
 *
 * Does not run prettier — the caller is expected to do that (the CLI
 * does, when configured).
 */
export function emit(raw: RawSchemaDoc, opts: EmitOptions): string {
  const schemas = [...raw.schemas].sort((a, b) => a.name.localeCompare(b.name))
  const source = opts.source ?? '/v1/schemas/production'
  const mode = opts.loose ? 'loose' : 'strict'
  const schemaNames = schemas.map((s) => s.name).join(', ')

  const header =
    '// AUTO-GENERATED — do not edit by hand.\n' +
    `// source: ${source}\n` +
    `// @barkpark-schema-hash: ${opts.schemaHash}\n` +
    `// codegen-version: ${CODEGEN_VERSION}\n` +
    `// mode: ${mode}\n` +
    `// schemas: ${schemaNames}\n` +
    '\n'

  const zodImport = emitZodPrelude() + '\n'

  const blocks: string[] = []
  const mapEntries: string[] = []
  const filterMapEntries: string[] = []

  for (const s of schemas) {
    blocks.push(renderSchemaBlock(s, opts.loose))
    const typeName = pascalOf(s.name)
    mapEntries.push(`  ${JSON.stringify(s.name)}: ${typeName};`)
    filterMapEntries.push(`  ${JSON.stringify(s.name)}: ${typeName}Filter;`)
  }

  const maps = renderMaps(mapEntries, filterMapEntries)

  return header + zodImport + PRELUDE + '\n' + blocks.join('\n') + '\n' + maps + '\n' + TYPED_CLIENT_RUNTIME
}

function renderSchemaBlock(s: RawSchema, loose: boolean): string {
  const typeName = pascalOf(s.name)
  const fields = s.fields.map((f) => mapField(f, loose))

  const metaFields = [
    `  _id: string;`,
    `  _type: ${JSON.stringify(s.name)};`,
    `  _draft: boolean;`,
    `  _publishedId: string;`,
    `  _createdAt: string;`,
    `  _updatedAt: string;`,
  ]
  const userFields = fields.map((f) => `  ${f.name}: ${f.tsType};`)

  const iface = `export interface ${typeName} {\n${metaFields.join('\n')}\n${userFields.join('\n')}\n}\n`

  const allFieldNames = ['_id', '_type', '_createdAt', '_updatedAt', ...fields.map((f) => f.name)]
  const fieldUnion = `export type ${typeName}Field = ${allFieldNames.map((n) => JSON.stringify(n)).join(' | ')};`

  const filterEntries: string[] = [
    `  _id: FilterField<'string', string>;`,
    `  _type: FilterField<'string', ${JSON.stringify(s.name)}>;`,
    `  _createdAt: FilterField<'date', string>;`,
    `  _updatedAt: FilterField<'date', string>;`,
  ]
  for (const f of fields) {
    if (f.kind === 'unfilterable') continue
    filterEntries.push(`  ${f.name}: FilterField<'${f.kind}', ${f.filterValueType}>;`)
  }
  const filter = `export type ${typeName}Filter = {\n${filterEntries.join('\n')}\n};\n`

  const zod = emitZodForSchema(s, loose) + '\n'

  return `${iface}\n${fieldUnion}\n${filter}\n${zod}`
}

function renderMaps(mapEntries: string[], filterMapEntries: string[]): string {
  if (mapEntries.length === 0) {
    return (
      `export type DocumentMap = {};\n` +
      `export type DocumentType = ${EMPTY_MAP_SENTINEL};\n` +
      `export type CollectionMap = DocumentMap;\n` +
      `export type CollectionSlug = DocumentType;\n` +
      `export type FilterMap = {};\n` +
      `export type BarkparkDocument = never;\n`
    )
  }
  return (
    `export type DocumentMap = {\n${mapEntries.join('\n')}\n};\n` +
    `export type DocumentType = keyof DocumentMap extends never\n` +
    `  ? ${EMPTY_MAP_SENTINEL}\n` +
    `  : keyof DocumentMap;\n` +
    `export type CollectionMap = DocumentMap;\n` +
    `export type CollectionSlug = DocumentType;\n\n` +
    `export type FilterMap = {\n${filterMapEntries.join('\n')}\n};\n` +
    `export type BarkparkDocument = DocumentMap[keyof DocumentMap];\n`
  )
}

function pascalOf(name: string): string {
  const cleaned = name.replace(/[^A-Za-z0-9_]/g, '_')
  return cleaned.charAt(0).toUpperCase() + cleaned.slice(1)
}
