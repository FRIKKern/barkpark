// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export type { BarkparkCodegenConfig, BarkparkSchemaJson, FieldDef, SchemaDef } from './types'
export { schemaEnvelopeSchema } from './types'
export type { SchemaUrlOptions } from './schema-url'
export { assertScopedPair, buildSchemaPath } from './schema-url'
export { fetchSchema } from './fetch-schema'
export type { FetchSchemaOptions } from './fetch-schema'
export { generateTypes } from './generate'
export type { GenerateOptions } from './generate'
import type { BarkparkCodegenConfig } from './types'

/**
 * Identity helper — returns `config` unchanged. Its only job is to give the
 * IDE a TypeScript-checked editing experience in `barkpark.config.ts`.
 *
 * @param config — {@link BarkparkCodegenConfig}
 * @returns The same `config` reference (no transformation).
 *
 * @example
 * // barkpark.config.ts
 * import { defineConfig } from '@barkpark/codegen'
 *
 * export default defineConfig({
 *   dataset: 'production',
 *   apiUrl: 'https://api.barkpark.cloud',
 *   output: './barkpark.types.ts',
 * })
 */
export function defineConfig(config: BarkparkCodegenConfig): BarkparkCodegenConfig {
  return config
}
