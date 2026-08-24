// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// Dataset export — streams every document from `GET /v1/data/export/:dataset`
// as NDJSON (one JSON document per line, chunked). Yielded lazily via an async
// generator so a large dataset never has to sit in memory at once — the
// backup/portability counterpart to Sanity's `dataset export`. Uses fetch +
// a ReadableStream reader (same approach as listen.ts), NOT the JSON transport,
// because the body is a stream, not a single JSON envelope.

import { scopePrefix } from './scope'
import { BarkparkAPIError, BarkparkNetworkError, assertStreamResponse } from './errors'
import type { BarkparkClientConfig, BarkparkDocument, ExportOptions } from './types'

// Parse one NDJSON line into a document, re-wrapping the raw SyntaxError a
// truncated stream or a proxy-injected HTML error page would otherwise throw.
// Every other failure in this generator is a typed Barkpark*Error, so consumers
// can rely on isBarkparkError() catching a corrupt-stream failure too.
function parseLine(line: string, status: number): BarkparkDocument {
  try {
    return JSON.parse(line) as BarkparkDocument
  } catch (cause) {
    throw new BarkparkAPIError('export: malformed NDJSON line', { status, cause })
  }
}

/**
 * Stream a dataset's documents as an async iterable
 * (`GET /v1/data/export/:dataset`). Prefer `client.exportDataset()`.
 *
 *   for await (const doc of exportDataset(config)) { … }
 */
export async function* exportDataset(
  config: BarkparkClientConfig,
  opts?: ExportOptions,
): AsyncGenerator<BarkparkDocument, void, unknown> {
  const params = new URLSearchParams()
  if (opts?.type) params.set('type', opts.type)
  if (opts?.perspective) params.set('perspective', opts.perspective)
  const qs = params.toString()

  const base = config.projectUrl.replace(/\/+$/, '')
  const path = `${scopePrefix(config)}/v1/data/export/${encodeURIComponent(config.dataset)}${qs ? `?${qs}` : ''}`

  const headers: Record<string, string> = {
    Accept: 'application/x-ndjson',
    'X-Barkpark-Api-Version': config.apiVersion,
  }
  if (config.token) headers.Authorization = `Bearer ${config.token}`

  const init: RequestInit = { headers }
  if (opts?.signal !== undefined) init.signal = opts.signal

  // [export-ignores-config-fetch] Every other path in this package honours the
  // caller's fetch override — transport.ts for all JSON calls, listen.ts for the
  // other stream. Export alone reached straight for the global, so a configured
  // `fetch` (MSW in a test suite, a tracing or auth-injecting wrapper in
  // production, a custom agent) was silently bypassed by dataset export and
  // nothing errored: the request simply went out through a different door than
  // the caller wired up. The runtime guard mirrors listen.ts's, so a runtime
  // with no fetch at all fails with a typed error rather than "fetch is not a
  // function".
  const fetchImpl = config.fetch ?? globalThis.fetch
  // No `typeof fetchImpl === 'function'` guard, unlike listen.ts: there the
  // fetch call sits OUTSIDE a try, so a missing global would surface as a raw
  // TypeError. Here it is already inside one, and the catch below re-wraps
  // anything it throws as a typed BarkparkNetworkError carrying the original as
  // `cause` — a guard would only restate that, for bytes this package does not
  // have. (Written, then verified: adding one changed no test outcome.)
  let response: Response
  try {
    response = await fetchImpl(`${base}${path}`, init)
  } catch (cause) {
    throw new BarkparkNetworkError('export: fetch failed', { cause })
  }

  assertStreamResponse(response, 'export')

  const reader = response.body.getReader()
  const decoder = new TextDecoder('utf-8')
  let buffer = ''
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      let nl: number
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).trim()
        buffer = buffer.slice(nl + 1)
        if (line) yield parseLine(line, response.status)
      }
    }
    // Flush any trailing line the stream ended without a newline on.
    const last = buffer.trim()
    if (last) yield parseLine(last, response.status)
  } finally {
    reader.releaseLock()
  }
}
