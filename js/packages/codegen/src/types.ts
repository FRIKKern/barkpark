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
}

/**
 * Shape produced by the Phoenix `/v1/schemas/:dataset` endpoint and consumed
 * by the codegen CLI.
 */
export interface BarkparkSchemaJson {
  types: unknown[]
}
