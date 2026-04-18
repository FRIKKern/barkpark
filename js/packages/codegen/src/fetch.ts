// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import type { RawSchemaDoc } from './_contract.js'

export class ApiError extends Error {
  readonly status: number
  readonly body: string
  constructor(message: string, status: number, body: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.body = body
  }
}

export class AuthFailedError extends ApiError {
  constructor(status: number, body: string) {
    super(
      `schema fetch failed with ${status}: set BARKPARK_TOKEN or --token to an admin token`,
      status,
      body,
    )
    this.name = 'AuthFailedError'
  }
}

export class NetworkFailedError extends ApiError {
  constructor(message: string, status = 0, body = '') {
    super(message, status, body)
    this.name = 'NetworkFailedError'
  }
}

function joinUrl(base: string, path: string): string {
  if (base.endsWith('/')) return base + path.replace(/^\//, '')
  return base + (path.startsWith('/') ? path : '/' + path)
}

export async function fetchSchema(
  apiUrl: string,
  dataset: string,
  token: string,
): Promise<RawSchemaDoc> {
  const url = joinUrl(apiUrl, `/v1/schemas/${encodeURIComponent(dataset)}`)
  let res: Response
  try {
    res = await fetch(url, {
      method: 'GET',
      headers: {
        Accept: 'application/json',
        Authorization: `Bearer ${token}`,
      },
    })
  } catch (err) {
    throw new NetworkFailedError(
      `network failure contacting ${url}: ${(err as Error).message}`,
    )
  }
  const body = await res.text()
  if (res.status === 401 || res.status === 403) {
    throw new AuthFailedError(res.status, body)
  }
  if (res.status >= 500) {
    throw new NetworkFailedError(
      `server error ${res.status} from ${url}`,
      res.status,
      body,
    )
  }
  if (!res.ok) {
    throw new ApiError(
      `schema fetch failed with ${res.status}: ${body.slice(0, 200)}`,
      res.status,
      body,
    )
  }
  try {
    return JSON.parse(body) as RawSchemaDoc
  } catch (err) {
    throw new ApiError(
      `schema endpoint returned non-JSON response: ${(err as Error).message}`,
      res.status,
      body,
    )
  }
}

export async function fetchMeta(
  apiUrl: string,
  dataset: string,
): Promise<{ currentDatasetSchemaHash?: string; [key: string]: unknown }> {
  const url = joinUrl(apiUrl, `/v1/meta?dataset=${encodeURIComponent(dataset)}`)
  let res: Response
  try {
    res = await fetch(url, {
      method: 'GET',
      headers: { Accept: 'application/json' },
    })
  } catch (err) {
    throw new NetworkFailedError(
      `network failure contacting ${url}: ${(err as Error).message}`,
    )
  }
  const body = await res.text()
  if (res.status >= 500) {
    throw new NetworkFailedError(
      `server error ${res.status} from ${url}`,
      res.status,
      body,
    )
  }
  if (!res.ok) {
    throw new ApiError(
      `meta fetch failed with ${res.status}: ${body.slice(0, 200)}`,
      res.status,
      body,
    )
  }
  try {
    return JSON.parse(body) as { currentDatasetSchemaHash?: string }
  } catch (err) {
    throw new ApiError(
      `meta endpoint returned non-JSON response: ${(err as Error).message}`,
      res.status,
      body,
    )
  }
}
