// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { z } from 'zod'

/**
 * Configuration for the `@barkpark/codegen` CLI. Typically authored in
 * `barkpark.config.ts` wrapped by {@link defineConfig}.
 */
export interface BarkparkCodegenConfig {
  /** Dataset slug to introspect (the `:dataset` in `/v1/schemas/:dataset`). */
  dataset: string
  /** Destination path for the generated TypeScript module. */
  output: string
  /** API base URL, e.g. `https://api.barkpark.cloud`. Falls back to `BARKPARK_API_URL`. */
  apiUrl?: string
  /** Bearer token. Falls back to the `BARKPARK_TOKEN` environment variable. */
  token?: string
  /**
   * Optional workspace slug. When provided together with {@link project},
   * schema fetches use the scoped path
   * `/w/<workspace>/p/<project>/v1/schemas/<dataset>`. Omit both to keep the
   * flat back-compat path `/v1/schemas/<dataset>`.
   */
  workspace?: string
  /**
   * Optional project slug. See {@link workspace} — both are required together
   * to select the scoped schema path.
   */
  project?: string
  /**
   * Schema-fetch deadline in milliseconds. `0` disables the deadline entirely
   * (mirrors `@barkpark/core`'s convention); omitted means the fetch layer's
   * 30s default. Settable three ways, strongest first: the `--timeout` CLI
   * flag, this config key, the `BARKPARK_SCHEMA_TIMEOUT_MS` environment
   * variable — the escape hatch for slow links or very large schemas.
   */
  timeoutMs?: number
}

/**
 * A single field definition inside a schema. Only the keys the mapper reads are
 * typed precisely; everything incidental (description, title, group, validation,
 * onix, …) is permitted but ignored via the index signature.
 */
export interface FieldDef {
  name: string
  type: string
  /**
   * Optionality flag. The live API spells this `required?` (literal question
   * mark in the key); older shapes may use `required`. The mapper reads both.
   */
  required?: boolean
  'required?'?: boolean
  /**
   * Element descriptor.
   *  - `array` (schema v1): an ARRAY of descriptors (element is `of[0]`).
   *  - `arrayOf` (schema v2): a SINGLE descriptor object.
   * Disambiguate via `Array.isArray(field.of)`.
   */
  of?: FieldDef | FieldDef[]
  /** Sub-fields for `composite`. */
  fields?: FieldDef[]
  /** Inline enum values for `select`. Strings, or objects carrying `.value`. */
  options?: Array<string | { value?: string; [k: string]: unknown }>
  /** Reference target(s) — ignored by the mapper (no target generic). */
  to?: unknown
  /** Reference target type — ignored by the mapper. */
  refType?: string
  /** Language keys for `localizedText`. */
  languages?: string[]
  [k: string]: unknown
}

/** A single schema (document type). */
export interface SchemaDef {
  name: string
  fields: FieldDef[]
  [k: string]: unknown
}

/**
 * Shape produced by the Phoenix `/v1/schemas/:dataset` endpoint and consumed
 * by the codegen CLI.
 */
export interface BarkparkSchemaJson {
  _schemaVersion: number
  datasetSchemaHash: string
  schemas: SchemaDef[]
}

/** zod schema for a single field. Loose — only the mapper-relevant keys. */
const fieldSchema: z.ZodType<FieldDef> = z.lazy(() =>
  z
    .object({
      name: z.string(),
      type: z.string(),
    })
    .passthrough(),
) as z.ZodType<FieldDef>

/** zod schema validating the `/v1/schemas/:dataset` envelope. */
export const schemaEnvelopeSchema = z
  .object({
    _schemaVersion: z.number(),
    datasetSchemaHash: z.string(),
    schemas: z.array(
      z
        .object({
          name: z.string(),
          fields: z.array(fieldSchema),
        })
        .passthrough(),
    ),
  })
  .passthrough() as z.ZodType<BarkparkSchemaJson>
