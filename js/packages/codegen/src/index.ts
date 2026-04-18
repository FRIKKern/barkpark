// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

export type {
  BarkparkCodegenConfig,
  EmittedField,
  FieldKind,
  RawField,
  RawSchema,
  RawSchemaDoc,
} from './types.js'

import type { BarkparkCodegenConfig } from './types.js'

export { emit, type EmitOptions } from './codegen/emit.js'
export { canonicalJson, sha256Canonical } from './codegen/hash.js'

/**
 * Identity helper for `barkpark.config.ts` authors — returns the config
 * unchanged but gives editors type-checking and completion.
 */
export function defineConfig(config: BarkparkCodegenConfig): BarkparkCodegenConfig {
  return config
}
