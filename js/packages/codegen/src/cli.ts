#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { readFile, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { resolve } from 'node:path'
import { cac } from 'cac'
import { buildSchemaPath } from './schema-url'
import { fetchSchema } from './fetch-schema'
import { generateTypes } from './generate'
import { schemaEnvelopeSchema, type BarkparkCodegenConfig } from './types'

const cli = cac('barkpark')

/**
 * Workspace + project are the two halves of a scoped schema path; supplying
 * only one silently falls back to the flat /v1/schemas/<dataset> path and
 * emits/prints the wrong (unscoped) content model. Enforce both-or-neither.
 */
function assertScopedPair(workspace: string | undefined, project: string | undefined): void {
  if (Boolean(workspace) !== Boolean(project)) {
    throw new Error(
      'workspace and project must be provided together (pass both --workspace and --project, or neither).',
    )
  }
}

cli
  .command('schema-path <dataset>', 'Print the schema-introspection path for a dataset')
  .option('--workspace <slug>', 'Workspace slug (scoped path; requires --project)')
  .option('--project <slug>', 'Project slug (scoped path; requires --workspace)')
  .action((dataset: string, options: { workspace?: string; project?: string }) => {
    try {
      assertScopedPair(options.workspace, options.project)
      const args: { dataset: string; workspace?: string; project?: string } = { dataset }
      if (options.workspace !== undefined) args.workspace = options.workspace
      if (options.project !== undefined) args.project = options.project
      process.stdout.write(buildSchemaPath(args) + '\n')
    } catch (err) {
      process.stderr.write(`${(err as Error).message}\n`)
      process.exitCode = 1
    }
  })

interface GenerateCliOptions {
  config?: string
  dataset?: string
  apiUrl?: string
  output?: string
  token?: string
  workspace?: string
  project?: string
  watch?: boolean
  /** Read the schema envelope from a local JSON file instead of fetching it. */
  from?: string
  /** Schema-fetch deadline in ms as typed on the command line (0 disables). */
  timeout?: string
}

/**
 * Cache-bust counter for config re-imports. The ESM module registry is keyed by
 * the resolved URL, so `--watch` re-importing the same config path returns the
 * module loaded on the FIRST run — the watcher then regenerates from the stale
 * config and prints `Re-wrote …`, a false success rather than a no-op. A unique
 * query per import makes each load a distinct URL.
 *
 * Monotonic counter, deliberately NOT `mtimeMs`: a filesystem with 1-second
 * timestamp granularity would give two saves in the same second the same key
 * and reintroduce exactly this bug on a subset of machines.
 *
 * Cost: every reload adds a permanent entry to the ESM registry (one small
 * module per save, never collected). Acceptable for a dev-loop CLI, but real.
 */
let configLoadSeq = 0

/** Load `barkpark.config.{ts,js,mjs}` if present; CLI flags override its values. */
async function loadConfig(configPath?: string): Promise<Partial<BarkparkCodegenConfig>> {
  if (!configPath) return {}
  const abs = resolve(process.cwd(), configPath)
  // The advertised `barkpark.config.ts` cannot load through the native ESM
  // loader on the Node 20 engines floor (ERR_UNKNOWN_FILE_EXTENSION), and
  // Node 22's type-stripping covers only erasable syntax (an enum throws
  // ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX) — so .ts/.mts/.cts configs go through
  // jiti. moduleCache + fsCache are OFF so `--watch` re-reads an edited
  // config: the same freshness guarantee the `?t=` cache-bust below gives
  // native loads (see loadconfig-cache.test.ts). The discriminating proof
  // lives in cli-ts-config.test.ts, which drives the BUILT CLI in a
  // subprocess: an in-process vitest import of a .ts file is transpiled by
  // Vite's module runner, so an in-process test passes with or without this
  // branch and proves nothing about the shipped loader.
  if (/\.[cm]?ts$/.test(abs)) {
    const { createJiti } = await import('jiti')
    const jiti = createJiti(import.meta.url, { moduleCache: false, fsCache: false })
    const mod = (await jiti.import(abs)) as { default?: BarkparkCodegenConfig }
    return mod.default ?? {}
  }
  const url = `${pathToFileURL(abs).href}?t=${++configLoadSeq}`
  const mod = (await import(url)) as {
    default?: BarkparkCodegenConfig
  }
  return mod.default ?? {}
}

/**
 * Parse a timeout value arriving as text (the `--timeout` flag or the
 * `BARKPARK_SCHEMA_TIMEOUT_MS` env var) into non-negative integer milliseconds.
 * `0` disables the deadline (core's convention). Anything else fails LOUD —
 * a mistyped deadline silently becoming the default is how a slow-link escape
 * hatch stops being one.
 */
function parseTimeoutMs(raw: string, source: string): number {
  const n = Number(raw)
  if (!Number.isInteger(n) || n < 0) {
    throw new Error(`Invalid ${source} value "${raw}": expected a non-negative integer of milliseconds (0 disables).`)
  }
  return n
}

/** Resolve the effective config from a config file overlaid with CLI flags. */
export async function resolveConfig(options: GenerateCliOptions): Promise<BarkparkCodegenConfig> {
  const file = await loadConfig(options.config)
  const merged: Partial<BarkparkCodegenConfig> = { ...file }
  if (options.dataset !== undefined) merged.dataset = options.dataset
  if (options.output !== undefined) merged.output = options.output
  if (options.apiUrl !== undefined) merged.apiUrl = options.apiUrl
  if (options.token !== undefined) merged.token = options.token
  if (options.workspace !== undefined) merged.workspace = options.workspace
  if (options.project !== undefined) merged.project = options.project
  if (merged.apiUrl === undefined && process.env['BARKPARK_API_URL']) {
    merged.apiUrl = process.env['BARKPARK_API_URL']
  }
  // Deadline precedence mirrors apiUrl: flag > config file > environment.
  if (options.timeout !== undefined) {
    merged.timeoutMs = parseTimeoutMs(options.timeout, '--timeout')
  }
  if (merged.timeoutMs === undefined && process.env['BARKPARK_SCHEMA_TIMEOUT_MS']) {
    merged.timeoutMs = parseTimeoutMs(
      process.env['BARKPARK_SCHEMA_TIMEOUT_MS'],
      'BARKPARK_SCHEMA_TIMEOUT_MS',
    )
  }

  // Workspace + project are the two halves of a scoped schema path; supplying
  // only one silently falls back to the flat /v1/schemas/<dataset> path and
  // emits types for the wrong (unscoped) content model. Enforce both-or-neither.
  assertScopedPair(merged.workspace, merged.project)

  if (!merged.dataset) throw new Error('Missing dataset: pass --dataset or set it in barkpark.config.')
  if (!merged.output) throw new Error('Missing output: pass --output or set it in barkpark.config.')
  if (!merged.apiUrl) {
    throw new Error('Missing apiUrl: pass --api-url, set BARKPARK_API_URL, or set it in barkpark.config.')
  }
  return merged as BarkparkCodegenConfig
}

/**
 * Read + zod-parse a local schema JSON file → generate → write once. Used by
 * `--from <file>` (network-free): this is the path the CI drift gate runs from
 * a committed schema fixture, so it must never touch the API. Returns the
 * absolute output path.
 */
async function runFromFile(options: GenerateCliOptions): Promise<string> {
  if (!options.from) throw new Error('runFromFile called without --from')
  // Read output/dataset from --config too (CLI flags stay overrides), so a
  // project already driving the fetch path from barkpark.config can add
  // `--from schema.json` without re-passing those flags.
  const file = await loadConfig(options.config)
  const output = options.output ?? file.output
  const dataset = options.dataset ?? file.dataset
  if (!output) throw new Error('Missing output: pass --output or set it in barkpark.config.')
  // The envelope carries only a hash, not a dataset name, so the banner needs a
  // dataset label threaded through. Default to the file path's intent: require it.
  if (!dataset) {
    throw new Error(
      'Missing dataset: pass --dataset or set it in barkpark.config. (used for the banner comment)',
    )
  }

  const fromAbs = resolve(process.cwd(), options.from)
  let raw: unknown
  try {
    raw = JSON.parse(await readFile(fromAbs, 'utf8'))
  } catch (cause) {
    throw new Error(`Could not read schema file ${fromAbs}: ${(cause as Error).message}`, { cause })
  }

  const parsed = schemaEnvelopeSchema.safeParse(raw)
  if (!parsed.success) {
    throw new Error(`Schema file ${fromAbs} failed validation: ${parsed.error.message}`)
  }

  const out = resolve(process.cwd(), output)
  const code = await generateTypes(parsed.data, { dataset, outputPath: out })
  await writeFile(out, code, 'utf8')
  return out
}

/** Fetch → generate → write once. Returns the absolute output path. */
async function runOnce(config: BarkparkCodegenConfig): Promise<string> {
  const fetchArgs: Parameters<typeof fetchSchema>[0] = {
    dataset: config.dataset,
    apiUrl: config.apiUrl!,
  }
  if (config.token !== undefined) fetchArgs.token = config.token
  if (config.workspace !== undefined) fetchArgs.workspace = config.workspace
  if (config.project !== undefined) fetchArgs.project = config.project
  if (config.timeoutMs !== undefined) fetchArgs.timeoutMs = config.timeoutMs

  const envelope = await fetchSchema(fetchArgs)
  const out = resolve(process.cwd(), config.output)
  const code = await generateTypes(envelope, { dataset: config.dataset, outputPath: out })
  await writeFile(out, code, 'utf8')
  return out
}

cli
  .command('generate', 'Fetch the dataset schema and emit barkpark.types.ts')
  .option('--config <path>', 'Path to barkpark.config.{ts,js,mjs}')
  .option('--dataset <slug>', 'Dataset slug to introspect')
  .option('--api-url <url>', 'API base URL (or set BARKPARK_API_URL)')
  .option('--output <path>', 'Output file path')
  .option('--token <token>', 'Bearer token (or set BARKPARK_TOKEN)')
  .option('--workspace <slug>', 'Workspace slug (scoped path; requires --project)')
  .option('--project <slug>', 'Project slug (scoped path; requires --workspace)')
  .option(
    '--from <file>',
    'Read the schema envelope from a local JSON file instead of fetching it (network-free; powers the CI drift gate)',
  )
  .option('--schema <file>', 'Alias for --from')
  .option(
    '--timeout <ms>',
    'Schema-fetch deadline in milliseconds; 0 disables (or set BARKPARK_SCHEMA_TIMEOUT_MS; default 30000)',
  )
  .option('--watch', 'Re-generate when the config file changes')
  .action(async (options: GenerateCliOptions & { schema?: string }) => {
    try {
      // --from / --schema: read a committed schema file, never the network.
      const fromFile = options.from ?? options.schema
      if (fromFile) {
        const out = await runFromFile({ ...options, from: fromFile })
        process.stdout.write(`Wrote ${out}\n`)
        // Config-file watching is fetch-path-only; --from is always one-shot even
        // when a --config supplies output/dataset (the schema file is not watched).
        if (options.watch) {
          process.stderr.write(
            '--watch has no effect with --from/--schema (nothing to watch): the one-shot output was written.\n',
          )
        }
        return
      }

      const config = await resolveConfig(options)
      const out = await runOnce(config)
      process.stdout.write(`Wrote ${out}\n`)

      if (options.watch && options.config) {
        const { watch } = await import('chokidar')
        const abs = resolve(process.cwd(), options.config)
        process.stdout.write(`Watching ${abs}…\n`)
        const watcher = watch(abs, { ignoreInitial: true })
        watcher.on('change', () => {
          void resolveConfig(options)
            .then(runOnce)
            .then((p) => process.stdout.write(`Re-wrote ${p}\n`))
            .catch((err: unknown) => process.stderr.write(`watch error: ${String(err)}\n`))
        })
      } else if (options.watch) {
        // Flag-/env-driven run with no config file: watching has nothing to observe.
        process.stderr.write(
          '--watch has no effect without --config: watching re-generates on config-file changes only; the one-shot output was written.\n',
        )
      }
    } catch (err) {
      process.stderr.write(`${(err as Error).message}\n`)
      process.exitCode = 1
    }
  })

cli.help()
cli.parse()
