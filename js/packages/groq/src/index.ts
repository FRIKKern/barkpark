// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * @packageDocumentation
 * @deferred 1.1 — `@barkpark/groq` is not implemented in 1.0. Importing this
 * module at runtime throws eagerly so projects cannot ship against an empty
 * surface. The GROQ path is tracked for 1.1; follow progress at
 * https://barkpark.dev/roadmap.
 *
 * For 1.0, use the filter-builder DSL on the core client:
 * ```ts
 * client.queryByType('post').where('status', '=', 'published').fetch()
 * ```
 */

throw new Error('@barkpark/groq is not implemented in 1.0. Deferred to 1.1 — see https://barkpark.dev/roadmap.')
export {}
