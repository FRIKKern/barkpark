// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/** Options for {@link buildSchemaPath}. */
export interface SchemaUrlOptions {
  /** Dataset slug (leaf). */
  dataset: string
  /** Optional workspace slug — must accompany {@link SchemaUrlOptions.project}. */
  workspace?: string
  /** Optional project slug — must accompany {@link SchemaUrlOptions.workspace}. */
  project?: string
}

/**
 * Build the schema-introspection request path.
 *
 * When both `workspace` and `project` are provided, returns the scoped path
 * `/w/<workspace>/p/<project>/v1/schemas/<dataset>`. Otherwise falls back to
 * the flat back-compat path `/v1/schemas/<dataset>` so existing users keep
 * working unchanged.
 *
 * @returns A leading-slash path (callers join it onto their API base URL).
 */
export function buildSchemaPath(options: SchemaUrlOptions): string {
  const { dataset, workspace, project } = options
  const leaf = `/v1/schemas/${encodeURIComponent(dataset)}`
  if (workspace && project) {
    return `/w/${encodeURIComponent(workspace)}/p/${encodeURIComponent(project)}${leaf}`
  }
  return leaf
}
