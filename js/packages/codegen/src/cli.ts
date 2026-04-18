// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import cac from 'cac'

import { AuthFailedError, NetworkFailedError } from './fetch.js'
import { runCheck } from './commands/check.js'
import { runCodegen } from './commands/codegen.js'
import { runInit } from './commands/init.js'
import { runSchemaExtract } from './commands/schema-extract.js'

const EXIT_OK = 0
const EXIT_DRIFT_OR_ERR = 1
const EXIT_AUTH = 2
const EXIT_NETWORK = 3
const EXIT_USAGE = 64

function compact<T extends Record<string, unknown>>(obj: T): Partial<T> {
  const out: Partial<T> = {}
  for (const key of Object.keys(obj) as Array<keyof T>) {
    const value = obj[key]
    if (value !== undefined) out[key] = value
  }
  return out
}

function readVersion(): string {
  try {
    const here = dirname(fileURLToPath(import.meta.url))
    const pkgPath = resolve(here, '..', 'package.json')
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8')) as { version?: string }
    return pkg.version ?? '0.0.0'
  } catch {
    return '0.0.0'
  }
}

function fail(err: unknown): never {
  if (err instanceof AuthFailedError) {
    process.stderr.write(`error: ${err.message}\n`)
    process.exit(EXIT_AUTH)
  }
  if (err instanceof NetworkFailedError) {
    process.stderr.write(`error: ${err.message}\n`)
    process.exit(EXIT_NETWORK)
  }
  const e = err as Error
  process.stderr.write(`error: ${e?.stack ?? String(err)}\n`)
  process.exit(EXIT_DRIFT_OR_ERR)
}

const cli = cac('barkpark')

cli
  .command('init', 'Scaffold barkpark.config.ts + .barkpark/ in the current directory')
  .option('--cwd <path>', 'Target directory (default: process.cwd())')
  .action(async (opts: { cwd?: string }) => {
    try {
      await runInit(opts.cwd !== undefined ? { cwd: opts.cwd } : {})
      process.exit(EXIT_OK)
    } catch (err) {
      fail(err)
    }
  })

cli
  .command('schema extract', 'Fetch /v1/schemas/:dataset and write cached schema.json')
  .option('--api-url <url>', 'Barkpark API base URL')
  .option('--token <token>', 'Admin bearer token')
  .option('--dataset <name>', 'Dataset name', { default: 'production' })
  .option('--out <path>', 'Output path', { default: '.barkpark/schema.json' })
  .action(
    async (opts: {
      'api-url'?: string
      apiUrl?: string
      token?: string
      dataset?: string
      out?: string
    }) => {
      try {
        await runSchemaExtract(
          compact({
            apiUrl: opts.apiUrl ?? opts['api-url'],
            token: opts.token,
            dataset: opts.dataset,
            out: opts.out,
          }),
        )
        process.exit(EXIT_OK)
      } catch (err) {
        fail(err)
      }
    },
  )

cli
  .command('codegen', 'Emit barkpark.types.ts from cached schema.json')
  .option('--in <path>', 'Schema JSON path', {
    default: '.barkpark/schema.json',
  })
  .option('--out <path>', 'Output types path', { default: 'barkpark.types.ts' })
  .option('--watch', 'Re-run on schema.json changes (chokidar, 200ms debounce)')
  .option('--loose', 'Map unknown field types to string')
  .option('--check', 'Exit non-zero if output would differ from existing file')
  .option('--no-prettier', 'Skip prettier formatting of generated output')
  .option('--source <text>', 'Source label embedded in generated header', {
    default: '/v1/schemas/production',
  })
  .action(
    async (opts: {
      in?: string
      out?: string
      watch?: boolean
      loose?: boolean
      check?: boolean
      prettier?: boolean
      source?: string
    }) => {
      try {
        await runCodegen(
          compact({
            in: opts.in,
            out: opts.out,
            watch: opts.watch,
            loose: opts.loose,
            check: opts.check,
            prettier: opts.prettier,
            source: opts.source,
          }),
        )
        process.exit(EXIT_OK)
      } catch (err) {
        fail(err)
      }
    },
  )

cli
  .command('check', 'Compare cached schema hash against live /v1/meta')
  .option('--api-url <url>', 'Barkpark API base URL')
  .option('--dataset <name>', 'Dataset name', { default: 'production' })
  .option('--cache <path>', 'Cached schema path', {
    default: '.barkpark/schema.json',
  })
  .action(
    async (opts: {
      'api-url'?: string
      apiUrl?: string
      dataset?: string
      cache?: string
    }) => {
      try {
        await runCheck(
          compact({
            apiUrl: opts.apiUrl ?? opts['api-url'],
            dataset: opts.dataset,
            cachePath: opts.cache,
          }),
        )
        process.exit(EXIT_OK)
      } catch (err) {
        fail(err)
      }
    },
  )

cli.help()
cli.version(readVersion())

try {
  cli.parse()
  if (process.argv.length <= 2) {
    cli.outputHelp()
    process.exit(EXIT_USAGE)
  }
} catch (err) {
  fail(err)
}
