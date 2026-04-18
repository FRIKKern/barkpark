// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { BarkparkClientConfig } from './types'
import { request, type TransportMethod, type TransportRequestOptions } from './transport'
import { BarkparkValidationError } from './errors'

/**
 * Escape hatch — returns the raw Response object for callers who need full control.
 * Pass any path relative to config.projectUrl (must start with '/').
 * Headers/body merge with transport defaults (Accept + Auth + request-tag).
 */
export async function fetchRawDoc(
  config: BarkparkClientConfig,
  path: string,
  init?: RequestInit,
): Promise<Response> {
  if (!path.startsWith('/')) {
    throw new BarkparkValidationError(`fetchRaw path must start with "/"`, { field: 'path' })
  }
  const method = ((init?.method ?? 'GET') as string).toUpperCase() as TransportMethod
  const opts: TransportRequestOptions = {
    method,
    rawResponse: true,
    kind: method === 'GET' ? 'read' : 'write',
  }
  if (init?.body !== undefined && init.body !== null) {
    opts.body = init.body as unknown
  }
  if (init?.headers !== undefined) {
    const h: Record<string, string> = {}
    if (init.headers instanceof Headers) {
      init.headers.forEach((v, k) => {
        h[k] = v
      })
    } else if (Array.isArray(init.headers)) {
      for (const [k, v] of init.headers) h[k] = v
    } else {
      for (const [k, v] of Object.entries(init.headers as Record<string, string>)) h[k] = v
    }
    opts.headers = h
  }
  if (init?.signal != null) opts.signal = init.signal
  const { data } = await request<Response>(config, path, opts)
  return data
}
