// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig } from './types'

/**
 * Path prefix that scopes every operation to a workspace + project.
 *
 * Returns `/w/${workspace}/p/${project}` only when BOTH `workspace` and
 * `project` are set on the config; otherwise returns `''` so callers fall back
 * to the flat `/v1/...` routes (back-compat). This is the single source the
 * per-operation path builders prepend — they must never compute the prefix
 * themselves.
 *
 * Lives in this leaf module (depends only on `./types`) so the per-operation
 * builders can import it without re-entering `./client`, which itself imports
 * the builders — keeping the dependency graph acyclic.
 *
 * @example
 *   scopePrefix({ workspace: 'acme', project: 'blog', ... }) // '/w/acme/p/blog'
 *   scopePrefix({ ...flatConfig })                           // ''
 */
export function scopePrefix(config: BarkparkClientConfig): string {
  if (
    typeof config.workspace === 'string' &&
    config.workspace.length > 0 &&
    typeof config.project === 'string' &&
    config.project.length > 0
  ) {
    return `/w/${encodeURIComponent(config.workspace)}/p/${encodeURIComponent(config.project)}`
  }
  return ''
}
