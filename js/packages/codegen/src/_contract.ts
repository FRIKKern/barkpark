// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Re-exports the subset of W5.1's engine surface that the CLI commands use.
// Keeps the integration seam small — if the engine shape changes, only this
// file needs to follow.

export type {
  BarkparkCodegenConfig,
  EmittedField,
  FieldKind,
  RawField,
  RawSchema,
  RawSchemaDoc,
} from './types.js'

export { emit, type EmitOptions } from './codegen/emit.js'
export { sha256Canonical } from './codegen/hash.js'
