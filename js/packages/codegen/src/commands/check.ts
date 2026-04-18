// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'

import { sha256Canonical } from '../_contract.js'
import type { RawSchemaDoc } from '../_contract.js'
import {
  NetworkFailedError,
  fetchMeta,
} from '../fetch.js'

export interface CheckOptions {
  apiUrl?: string
  dataset?: string
  cachePath?: string
}

export async function runCheck(opts: CheckOptions = {}): Promise<void> {
  const apiUrl =
    opts.apiUrl ?? process.env.BARKPARK_API_URL ?? 'http://localhost:4000'
  const dataset = opts.dataset ?? 'production'
  const cachePath = resolve(opts.cachePath ?? '.barkpark/schema.json')

  let raw: string
  try {
    raw = await readFile(cachePath, 'utf8')
  } catch {
    process.stderr.write(
      `error: no cached schema at ${cachePath} — run \`barkpark schema extract\`\n`,
    )
    process.exit(1)
    return
  }

  let doc: RawSchemaDoc
  try {
    doc = JSON.parse(raw) as RawSchemaDoc
  } catch (err) {
    process.stderr.write(
      `error: invalid JSON at ${cachePath}: ${(err as Error).message}\n`,
    )
    process.exit(1)
    return
  }

  const localHash =
    typeof doc.datasetSchemaHash === 'string' && doc.datasetSchemaHash.length > 0
      ? doc.datasetSchemaHash
      : sha256Canonical(doc)

  let meta: { currentDatasetSchemaHash?: string; [key: string]: unknown }
  try {
    meta = await fetchMeta(apiUrl, dataset)
  } catch (err) {
    if (err instanceof NetworkFailedError) {
      process.stderr.write(
        `error: ${err.message}\n  check inconclusive — network unreachable\n`,
      )
      process.exit(3)
      return
    }
    process.stderr.write(
      `error: meta fetch failed: ${(err as Error).message}\n`,
    )
    process.exit(3)
    return
  }

  const remoteHash = meta.currentDatasetSchemaHash
  if (typeof remoteHash !== 'string' || remoteHash.length === 0) {
    process.stderr.write(
      `error: /v1/meta response missing currentDatasetSchemaHash\n  check inconclusive\n`,
    )
    process.exit(3)
    return
  }

  if (localHash === remoteHash) {
    process.stdout.write(
      `check: schema hashes match (${localHash.slice(0, 12)})\n`,
    )
    return
  }

  process.stderr.write(
    `drift: local  ${localHash}\n       remote ${remoteHash}\n` +
      '  schema drift detected — run `barkpark schema extract && barkpark codegen`\n',
  )
  process.exit(1)
}
