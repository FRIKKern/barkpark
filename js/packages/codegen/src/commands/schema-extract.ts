// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdir, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

import {
  AuthFailedError,
  NetworkFailedError,
  fetchSchema,
} from '../fetch.js'
import type { RawSchemaDoc } from '../_contract.js'

export interface SchemaExtractOptions {
  apiUrl?: string
  token?: string
  dataset?: string
  out?: string
}

function isLocalApiUrl(apiUrl: string): boolean {
  return /localhost|127\.0\.0\.1|0\.0\.0\.0/.test(apiUrl)
}

function countSchemas(doc: RawSchemaDoc): number {
  return Array.isArray(doc.schemas) ? doc.schemas.length : 0
}

export async function runSchemaExtract(
  opts: SchemaExtractOptions = {},
): Promise<void> {
  const apiUrl =
    opts.apiUrl ?? process.env.BARKPARK_API_URL ?? 'http://localhost:4000'
  const dataset = opts.dataset ?? 'production'
  const out = resolve(opts.out ?? '.barkpark/schema.json')

  const explicitToken = opts.token ?? process.env.BARKPARK_TOKEN
  const token = explicitToken ?? 'barkpark-dev-token'
  if (!explicitToken && !isLocalApiUrl(apiUrl)) {
    process.stderr.write(
      'warn: no token provided; falling back to dev token against non-local apiUrl — expect 401\n',
    )
  }

  let doc: RawSchemaDoc
  try {
    doc = await fetchSchema(apiUrl, dataset, token)
  } catch (err) {
    if (err instanceof AuthFailedError) {
      process.stderr.write(`error: ${err.message}\n`)
      process.exit(2)
    }
    if (err instanceof NetworkFailedError) {
      process.stderr.write(
        `error: ${err.message}\n  network unreachable; run with --offline to use cached schema\n`,
      )
      process.exit(3)
    }
    throw err
  }

  await mkdir(dirname(out), { recursive: true })
  const body = JSON.stringify(doc, null, 2) + '\n'
  await writeFile(out, body, 'utf8')

  const hash =
    typeof doc.datasetSchemaHash === 'string'
      ? doc.datasetSchemaHash
      : undefined
  const shortHash = hash ? hash.slice(0, 12) : '(no server hash)'
  process.stdout.write(
    `wrote ${out} (${countSchemas(doc)} schemas, hash ${shortHash})\n`,
  )
}
