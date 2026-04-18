// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * Configuration for the `@barkpark/codegen` CLI. Typically authored in
 * `barkpark.config.ts` wrapped by {@link defineConfig}.
 */
export interface BarkparkCodegenConfig {
  /** Path to a JSON schema dump fetched from `/v1/schemas/:dataset`. */
  input: string
  /** Destination path for the generated TypeScript module. */
  output: string
}

/**
 * Shape produced by the Phoenix `/v1/schemas/:dataset` endpoint and consumed
 * by the codegen CLI.
 */
export interface BarkparkSchemaJson {
  types: unknown[]
}
