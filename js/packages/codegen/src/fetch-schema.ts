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
  /**
   * Deadline for the whole schema fetch — headers AND body read — in
   * milliseconds. Defaults to `30_000`, matching the read-request default of
   * `@barkpark/core`'s transport; `0` disables the deadline.
   */
  timeoutMs?: number
}

/** Join an API base URL with a leading-slash path, trimming a trailing slash. */
function joinUrl(base: string, path: string): string {
  return base.replace(/\/+$/, '') + path
}

/** The one timeout error shape — every deadline path rejects with this text. */
function timeoutError(url: string, ms: number): Error {
  return new Error(`Schema fetch timed out after ${ms}ms for ${url}`)
}

/**
 * Race `promise` against `signal`'s abort so a phase that ignores the signal
 * still ends at the deadline. The `signal` is only ADVISORY to an injected
 * `fetchImpl` (and to whatever `Response` it returns), so every awaited phase —
 * the fetch, the JSON body read, and the best-effort error-body read — is
 * wrapped. The abort listener is removed when the race settles so a `--watch`
 * loop cannot accumulate handlers.
 */
function withDeadline<T>(
  promise: Promise<T>,
  signal: AbortSignal | undefined,
  url: string,
  ms: number,
): Promise<T> {
  if (signal === undefined) return promise
  let onAbort!: () => void
  const deadline = new Promise<never>((_resolve, reject) => {
    onAbort = () => reject(timeoutError(url, ms))
    if (signal.aborted) onAbort()
    else signal.addEventListener('abort', onAbort, { once: true })
  })
  return Promise.race([promise, deadline]).finally(() => {
    signal.removeEventListener('abort', onAbort)
  })
}

/**
 * Fetch the schema envelope for a dataset from `/v1/schemas/:dataset` and
 * validate it with zod. Throws a clear error on a missing token, a non-2xx
 * response, a malformed envelope, or a stalled server (see
 * {@link FetchSchemaOptions.timeoutMs}).
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

  const timeoutMs = options.timeoutMs ?? 30_000
  const signal = timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : undefined

  const doFetch = options.fetchImpl ?? fetch
  let res: Response
  try {
    const init: RequestInit = {
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/json',
      },
    }
    if (signal !== undefined) init.signal = signal
    res = await withDeadline(Promise.resolve(doFetch(url, init)), signal, url, timeoutMs)
  } catch (cause) {
    if (signal?.aborted === true) throw timeoutError(url, timeoutMs)
    throw new Error(`Schema fetch failed for ${url}: ${(cause as Error).message}`, { cause })
  }

  if (!res.ok) {
    let body = ''
    try {
      body = (await withDeadline(Promise.resolve(res.text()), signal, url, timeoutMs)).slice(0, 500)
    } catch (cause) {
      // The body is best-effort context — but a body read that never settles is
      // not, so a deadline hit still surfaces as the timeout error.
      if (signal?.aborted === true) throw timeoutError(url, timeoutMs)
      void cause
    }
    throw new Error(
      `Schema fetch ${res.status} ${res.statusText} for ${url}${body ? `: ${body}` : ''}`,
    )
  }

  let json: unknown
  try {
    json = await withDeadline(Promise.resolve(res.json()), signal, url, timeoutMs)
  } catch (cause) {
    if (signal?.aborted === true) throw timeoutError(url, timeoutMs)
    throw new Error(`Schema response from ${url} was not valid JSON`, { cause })
  }

  const parsed = schemaEnvelopeSchema.safeParse(json)
  if (!parsed.success) {
    throw new Error(`Schema response from ${url} failed validation: ${parsed.error.message}`)
  }
  return parsed.data
}
