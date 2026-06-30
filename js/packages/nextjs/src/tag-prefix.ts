// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * The single source of truth for the cache-tag namespace prefix.
 *
 * Returns the SCOPED `bp:ws:<workspace>:p:<project>:ds:<dataset>` prefix when
 * BOTH a workspace and a project slug resolve (s7 scoped payloads); otherwise
 * the LEGACY flat `bp:ds:<dataset>` prefix (back-compat).
 *
 * This format is a CONTRACT shared across three sites that must agree exactly or
 * cache invalidation silently breaks: the write side (`defineActions` fans out
 * `<prefix>:doc:<id>` / `:type:<type>` on mutate), the read side (`server` tags
 * each fetch with the same), and the webhook revalidate fallback. Any of them
 * drifting from this shape means a write/webhook never invalidates the matching
 * read. Keep it here, not copied.
 */
export function formatTagPrefix(dataset: string, workspace?: string, project?: string): string {
  if (
    typeof workspace === 'string' &&
    workspace.length > 0 &&
    typeof project === 'string' &&
    project.length > 0
  ) {
    return `bp:ws:${workspace}:p:${project}:ds:${dataset}`
  }
  return `bp:ds:${dataset}`
}
