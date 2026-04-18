// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * A single field within a Barkpark schema, as returned by the
 * `/v1/schemas/:dataset` envelope. Both `required` and the wire-shape
 * `"required?"` key are accepted — the Phoenix controller emits the latter,
 * but legacy snapshots sometimes carry the former.
 */
export interface RawField {
  name: string
  title?: string
  type: string
  required?: boolean
  'required?'?: boolean
  rows?: number
  options?: ReadonlyArray<string | { value: string; title?: string }>
  refType?: string
  to?: ReadonlyArray<{ type: string; name?: string }>
  of?: ReadonlyArray<{ type: string; name?: string; to?: ReadonlyArray<{ type: string }> }>
}

/**
 * One schema (document type) in the Barkpark envelope.
 */
export interface RawSchema {
  id?: string
  name: string
  title?: string
  fields: ReadonlyArray<RawField>
  visibility?: 'public' | 'private' | string
  icon?: string | null
  schemaHash?: string
}

/**
 * The full envelope returned by `GET /v1/schemas/:dataset`.
 */
export interface RawSchemaDoc {
  schemas: ReadonlyArray<RawSchema>
  _schemaVersion?: number
  datasetSchemaHash?: string
}

/**
 * Filter-op kind classification used to derive the generated `FilterMap`.
 * `"unfilterable"` signals the field is emitted on the document interface
 * but excluded from the filter map (richText, image, array).
 */
export type FieldKind =
  | 'string'
  | 'number'
  | 'date'
  | 'boolean'
  | 'slug'
  | 'reference'
  | 'unfilterable'

/**
 * The result of mapping a `RawField` to the generated TypeScript surface:
 * the literal TS type to emit on the document interface, the filter kind,
 * the filter value type (for `FilterField<K, V>`), and whether the field
 * is required on write-side input validation.
 */
export interface EmittedField {
  name: string
  tsType: string
  kind: FieldKind
  filterValueType: string
  required: boolean
}

/**
 * User-supplied configuration for `@barkpark/codegen`. All keys are
 * optional; the CLI fills in defaults (apiUrl, dataset=production, etc.).
 */
export interface BarkparkCodegenConfig {
  apiUrl?: string
  token?: string
  dataset?: string
  schema?: {
    cachePath?: string
  }
  codegen?: {
    out?: string
    loose?: boolean
    prettier?: boolean
  }
  watch?: {
    debounceMs?: number
  }
}
