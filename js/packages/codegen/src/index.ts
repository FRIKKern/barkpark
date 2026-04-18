// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export type { BarkparkCodegenConfig, BarkparkSchemaJson } from './types'
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
 *   input: './schema.json',
 *   output: './types/barkpark.ts',
 * })
 */
export function defineConfig(config: BarkparkCodegenConfig): BarkparkCodegenConfig {
  return config
}
