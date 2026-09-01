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
 * Is this half of the scope pair actually supplied?
 *
 * `undefined` and `''` both mean "not supplied". The empty string matters: it is
 * falsy, so the original `workspace && project` guard swallowed an empty half
 * exactly the way it swallowed a missing one — and `@barkpark/core` rejects an
 * empty slug a step earlier, in its `SLUG_RE` check, so refusing it here keeps
 * the two packages agreeing on which inputs are scoped.
 */
function isProvided(value: string | undefined): boolean {
  return value !== undefined && value !== ''
}

/**
 * Enforce that `workspace` and `project` are supplied together — both (a scoped
 * read) or neither (the flat back-compat read), never one.
 *
 * A half-set pair used to fall through to the flat `/v1/schemas/<dataset>` path.
 * That is a guard that fails OPEN: nothing errored, nothing warned, and the
 * caller's bearer token was sent to an endpoint they never asked for, producing
 * a `barkpark.types.ts` generated from the wrong tenant's content model. A
 * partially-specified scope is a mistake, and every entry point must say so.
 *
 * Mirrors `@barkpark/core`'s `client.ts` check, message included, so the same
 * invariant reads the same way wherever a developer hits it in this SDK.
 *
 * @throws Error when exactly one of `workspace` / `project` is provided.
 */
export function assertScopedPair(
  workspace: string | undefined,
  project: string | undefined,
): void {
  if (isProvided(workspace) !== isProvided(project)) {
    throw new Error(
      'workspace and project must be set together (both = scoped routes, neither = flat /v1)',
    )
  }
}

/**
 * Build the schema-introspection request path.
 *
 * When both `workspace` and `project` are provided, returns the scoped path
 * `/w/<workspace>/p/<project>/v1/schemas/<dataset>`. When neither is provided,
 * returns the flat back-compat path `/v1/schemas/<dataset>` so existing users
 * keep working unchanged. Supplying exactly one **throws** — see
 * {@link assertScopedPair}.
 *
 * This is the chokepoint every scoped-URL entry point in the package runs
 * through (`fetchSchema`, the `schema-path` and `generate` CLI commands, and
 * direct callers of this function, which is exported from the package root), so
 * guarding here covers all of them by construction — including plain-JS callers
 * that get no help from the types.
 *
 * @returns A leading-slash path (callers join it onto their API base URL).
 * @throws Error when exactly one of `workspace` / `project` is provided.
 */
export function buildSchemaPath(options: SchemaUrlOptions): string {
  const { dataset, workspace, project } = options
  assertScopedPair(workspace, project)
  const leaf = `/v1/schemas/${encodeURIComponent(dataset)}`
  if (workspace && project) {
    return `/w/${encodeURIComponent(workspace)}/p/${encodeURIComponent(project)}${leaf}`
  }
  return leaf
}
