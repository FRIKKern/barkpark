// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { EmittedField, RawField } from '../types.js'

/**
 * Map a raw schema field to the generated TypeScript surface plus its
 * filter-op kind. Port of Spike B `codegen.ts` L49–81 with two
 * additions:
 *
 * 1. **`required` tracking.** Either `required` or `"required?"` wire key
 *    is accepted; value propagates to `EmittedField.required`. The TS type
 *    is **not** widened with `| null` for optional fields — the `required`
 *    flag drives Zod `.optional()` emission only.
 * 2. **Typed arrays.** If `f.of` is present, the element specs drive the
 *    emitted type (`string[]`, `Array<{ _type: "reference"; _ref: string }>`,
 *    union for multi-element `of`). Absent `of` falls back to the Spike B
 *    default `unknown[]`, preserving byte-compatibility with the golden
 *    output for seed data.
 *
 * In loose mode, unknown field types degrade to `string/string/string`
 * instead of the strict `unknown/unfilterable/never`.
 */
export function mapField(f: RawField, loose: boolean): EmittedField {
  const required = f['required?'] ?? f.required ?? false

  switch (f.type) {
    case 'string':
      return {
        name: f.name,
        tsType: 'string',
        kind: 'string',
        filterValueType: 'string',
        required,
      }
    case 'slug':
      return {
        name: f.name,
        tsType: "{ _type: 'slug'; current: string }",
        kind: 'slug',
        filterValueType: 'string',
        required,
      }
    case 'text':
      return {
        name: f.name,
        tsType: 'string',
        kind: 'string',
        filterValueType: 'string',
        required,
      }
    case 'richText':
      return {
        name: f.name,
        tsType: 'unknown[]',
        kind: 'unfilterable',
        filterValueType: 'never',
        required,
      }
    case 'image':
      return {
        name: f.name,
        tsType: "{ _type: 'image'; asset: { _ref: string } } | null",
        kind: 'unfilterable',
        filterValueType: 'never',
        required,
      }
    case 'boolean':
      return {
        name: f.name,
        tsType: 'boolean',
        kind: 'boolean',
        filterValueType: 'boolean',
        required,
      }
    case 'datetime':
      return {
        name: f.name,
        tsType: 'string',
        kind: 'date',
        filterValueType: 'string',
        required,
      }
    case 'color':
      return {
        name: f.name,
        tsType: 'string',
        kind: 'string',
        filterValueType: 'string',
        required,
      }
    case 'select': {
      const t = selectUnion(f) ?? 'string'
      return {
        name: f.name,
        tsType: t,
        kind: 'string',
        filterValueType: t,
        required,
      }
    }
    case 'number':
      return {
        name: f.name,
        tsType: 'number',
        kind: 'number',
        filterValueType: 'number',
        required,
      }
    case 'reference':
      return {
        name: f.name,
        tsType: "{ _type: 'reference'; _ref: string }",
        kind: 'reference',
        filterValueType: 'string',
        required,
      }
    case 'array':
      return {
        name: f.name,
        tsType: emitArrayType(f),
        kind: 'unfilterable',
        filterValueType: 'never',
        required,
      }
    default:
      if (loose) {
        return {
          name: f.name,
          tsType: 'string',
          kind: 'string',
          filterValueType: 'string',
          required,
        }
      }
      return {
        name: f.name,
        tsType: 'unknown',
        kind: 'unfilterable',
        filterValueType: 'never',
        required,
      }
  }
}

function selectUnion(f: RawField): string | null {
  const opts = f.options
  if (!opts || opts.length === 0) return null
  const values: string[] = []
  for (const o of opts) {
    if (typeof o === 'string') values.push(o)
    else if (o && typeof o === 'object' && typeof o.value === 'string') values.push(o.value)
  }
  if (values.length === 0) return null
  return values.map((v) => JSON.stringify(v)).join(' | ')
}

function emitArrayType(f: RawField): string {
  const of = f.of
  if (!of || of.length === 0) return 'unknown[]'
  const elems = of.map(mapOfElement)
  if (elems.length === 1) {
    const only = elems[0]!
    return needsParens(only) ? `Array<${only}>` : `${only}[]`
  }
  return `Array<${elems.join(' | ')}>`
}

function mapOfElement(spec: { type: string; name?: string; to?: ReadonlyArray<{ type: string }> }): string {
  switch (spec.type) {
    case 'string':
    case 'text':
    case 'color':
    case 'datetime':
      return 'string'
    case 'number':
      return 'number'
    case 'boolean':
      return 'boolean'
    case 'slug':
      return "{ _type: 'slug'; current: string }"
    case 'reference':
      return "{ _type: 'reference'; _ref: string }"
    case 'image':
      return "{ _type: 'image'; asset: { _ref: string } }"
    case 'richText':
    case 'array':
      return 'unknown'
    default:
      return 'unknown'
  }
}

function needsParens(ts: string): boolean {
  // Any non-simple identifier/object-literal must be wrapped in Array<>
  // to avoid `{...}[]` ambiguity or `a | b[]` mis-precedence.
  return !/^[A-Za-z_$][\w$]*$/.test(ts)
}
