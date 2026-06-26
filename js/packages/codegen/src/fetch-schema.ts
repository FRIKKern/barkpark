// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { buildSchemaPath } from './schema-url'
import { schemaEnvelopeSchema, type BarkparkSchemaJson } from './types'

/** Options for {@link fetchSchema}. */
export interface FetchSchemaOptions {
  /** Dataset slug (the `:dataset` in `/v1/schemas/:dataset`). */
  dataset: string
  /** API base URL, e.g. `https://api.barkpark.cloud`. */
  apiUrl: string
  /** Bearer token. Falls back to `process.env.BARKPARK_TOKEN`. */
  token?: string
  /** Optional workspace slug (scoped path; requires {@link project}). */
  workspace?: string
  /** Optional project slug (scoped path; requires {@link workspace}). */
  project?: string
  /** Injectable fetch — defaults to the global `fetch`. */
  fetchImpl?: typeof fetch
}

/** Join an API base URL with a leading-slash path, trimming a trailing slash. */
function joinUrl(base: string, path: string): string {
  return base.replace(/\/+$/, '') + path
}

/**
 * Fetch the schema envelope for a dataset from `/v1/schemas/:dataset` and
 * validate it with zod. Throws a clear error on a missing token, a non-2xx
 * response, or a malformed envelope.
 */
export async function fetchSchema(options: FetchSchemaOptions): Promise<BarkparkSchemaJson> {
  const { dataset, apiUrl, workspace, project } = options
  const token = options.token ?? process.env['BARKPARK_TOKEN']
  if (!token) {
    throw new Error(
      'No Barkpark token: set BARKPARK_TOKEN or pass `token` in barkpark.config.ts.',
    )
  }
  if (!apiUrl) {
    throw new Error('No API URL: set BARKPARK_API_URL or pass `apiUrl` in barkpark.config.ts.')
  }

  const pathArgs: { dataset: string; workspace?: string; project?: string } = { dataset }
  if (workspace !== undefined) pathArgs.workspace = workspace
  if (project !== undefined) pathArgs.project = project
  const url = joinUrl(apiUrl, buildSchemaPath(pathArgs))

  const doFetch = options.fetchImpl ?? fetch
  let res: Response
  try {
    res = await doFetch(url, {
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/json',
      },
    })
  } catch (cause) {
    throw new Error(`Schema fetch failed for ${url}: ${(cause as Error).message}`, { cause })
  }

  if (!res.ok) {
    let body = ''
    try {
      body = (await res.text()).slice(0, 500)
    } catch {
      // ignore — body is best-effort context
    }
    throw new Error(
      `Schema fetch ${res.status} ${res.statusText} for ${url}${body ? `: ${body}` : ''}`,
    )
  }

  let json: unknown
  try {
    json = await res.json()
  } catch (cause) {
    throw new Error(`Schema response from ${url} was not valid JSON`, { cause })
  }

  const parsed = schemaEnvelopeSchema.safeParse(json)
  if (!parsed.success) {
    throw new Error(`Schema response from ${url} failed validation: ${parsed.error.message}`)
  }
  return parsed.data
}
