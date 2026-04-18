// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { RawField, RawSchema } from '../types.js'

const SYSTEM_FIELDS = new Set(['_id', '_type', '_draft', '_publishedId', '_createdAt', '_updatedAt'])

/**
 * The single-line import needed by every generated file that emits Zod
 * input schemas. Emitted once near the top of the output, above PRELUDE.
 */
export function emitZodPrelude(): string {
  return 'import { z } from "zod";\n'
}

/**
 * Emit a `export const <Pascal>InputSchema = z.object({...}).strict()`
 * (or `.passthrough()` in loose mode) for the user-write-side input
 * validation of a single document type. System fields (`_id`, `_type`,
 * etc.) are omitted — they are server-assigned.
 *
 * Fields with `required: false` (or the wire `"required?": false`) get
 * `.optional()`.
 */
export function emitZodForSchema(schema: RawSchema, loose: boolean): string {
  const name = pascalOf(schema.name)
  const shape: string[] = []
  for (const f of schema.fields) {
    if (SYSTEM_FIELDS.has(f.name)) continue
    const required = f['required?'] ?? f.required ?? false
    const validator = zodForField(f, loose)
    const suffix = required ? '' : '.optional()'
    shape.push(`  ${safeKey(f.name)}: ${validator}${suffix},`)
  }
  const body = shape.length === 0 ? '{}' : `{\n${shape.join('\n')}\n}`
  const closure = loose ? '.passthrough()' : '.strict()'
  return `export const ${name}InputSchema = z.object(${body})${closure};`
}

function zodForField(f: RawField, loose: boolean): string {
  switch (f.type) {
    case 'string':
    case 'text':
    case 'color':
    case 'datetime':
      return 'z.string()'
    case 'number':
      return 'z.number()'
    case 'boolean':
      return 'z.boolean()'
    case 'slug':
      return 'z.object({ _type: z.literal("slug"), current: z.string() }).strict()'
    case 'reference':
      return 'z.object({ _type: z.literal("reference"), _ref: z.string() }).strict()'
    case 'image':
      return 'z.object({ _type: z.literal("image"), asset: z.object({ _ref: z.string() }).strict() }).strict().nullable()'
    case 'richText':
    case 'array':
      return 'z.array(z.unknown())'
    case 'select': {
      const values = selectValues(f)
      if (values.length === 0) return 'z.string()'
      const tuple = values.map((v) => JSON.stringify(v)).join(', ')
      return `z.enum([${tuple}] as const)`
    }
    default:
      return loose ? 'z.string()' : 'z.unknown()'
  }
}

function selectValues(f: RawField): string[] {
  const opts = f.options
  if (!opts) return []
  const out: string[] = []
  for (const o of opts) {
    if (typeof o === 'string') out.push(o)
    else if (o && typeof o === 'object' && typeof o.value === 'string') out.push(o.value)
  }
  return out
}

function pascalOf(name: string): string {
  const cleaned = name.replace(/[^A-Za-z0-9_]/g, '_')
  return cleaned.charAt(0).toUpperCase() + cleaned.slice(1)
}

function safeKey(name: string): string {
  return /^[A-Za-z_$][\w$]*$/.test(name) ? name : JSON.stringify(name)
}
