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

/**
 * `${scopePrefix}/v1/data/<route>/<dataset>`: the head of every `/v1/data`
 * path. Built in one place so the path builders stay short; core sits on a hard
 * gzipped size cap (js/CLAUDE.md "Bundle budget").
 *
 * @internal A path fragment for this package's own builders. Callers address
 * routes through the named client methods.
 */
export function dataPath(config: BarkparkClientConfig, route: string): string {
  return `${scopePrefix(config)}/v1/data/${route}/${encodeURIComponent(config.dataset)}`
}
