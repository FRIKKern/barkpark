// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'

import { emit, sha256Canonical } from '../_contract.js'
import type { RawSchemaDoc } from '../_contract.js'
import { startWatch } from '../watch.js'

export interface CodegenOptions {
  in?: string
  out?: string
  loose?: boolean
  watch?: boolean
  check?: boolean
  prettier?: boolean
  source?: string
}

interface PrettierLike {
  format: (src: string, opts: { parser: string }) => Promise<string> | string
}

async function tryLoadPrettier(): Promise<PrettierLike | null> {
  try {
    const mod = (await import('prettier')) as unknown as {
      default?: PrettierLike
    } & PrettierLike
    return (mod.default ?? mod) as PrettierLike
  } catch {
    return null
  }
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p)
    return true
  } catch {
    return false
  }
}

function firstDiff(a: string, b: string, max = 40): string {
  const al = a.split('\n')
  const bl = b.split('\n')
  const lines: string[] = []
  const n = Math.max(al.length, bl.length)
  let shown = 0
  for (let i = 0; i < n && shown < max; i++) {
    if (al[i] !== bl[i]) {
      if (i < al.length) {
        lines.push(`- ${al[i] ?? ''}`)
        shown++
      }
      if (shown < max && i < bl.length) {
        lines.push(`+ ${bl[i] ?? ''}`)
        shown++
      }
    }
  }
  return lines.join('\n')
}

function countSchemas(doc: RawSchemaDoc): number {
  return Array.isArray(doc.schemas) ? doc.schemas.length : 0
}

async function runOnce(opts: CodegenOptions): Promise<void> {
  const inPath = resolve(opts.in ?? '.barkpark/schema.json')
  const outPath = resolve(opts.out ?? 'barkpark.types.ts')
  const loose = opts.loose ?? false
  const check = opts.check ?? false
  const usePrettier = opts.prettier !== false
  const source = opts.source ?? '/v1/schemas/production'

  let raw: string
  try {
    raw = await readFile(inPath, 'utf8')
  } catch (err) {
    process.stderr.write(
      `error: cannot read schema at ${inPath}: ${(err as Error).message}\n  run \`barkpark schema extract\` first\n`,
    )
    process.exit(1)
    return
  }

  let doc: RawSchemaDoc
  try {
    doc = JSON.parse(raw) as RawSchemaDoc
  } catch (err) {
    process.stderr.write(
      `error: invalid JSON at ${inPath}: ${(err as Error).message}\n`,
    )
    process.exit(1)
    return
  }

  const schemaHash =
    typeof doc.datasetSchemaHash === 'string' && doc.datasetSchemaHash.length > 0
      ? doc.datasetSchemaHash
      : sha256Canonical(doc)

  let generated = emit(doc, { loose, schemaHash, source })

  if (usePrettier) {
    const prettier = await tryLoadPrettier()
    if (prettier) {
      generated = await prettier.format(generated, { parser: 'typescript' })
    } else {
      process.stderr.write(
        'warn: prettier not available — emitting unformatted output\n',
      )
    }
  }

  const count = countSchemas(doc)
  const shortHash = schemaHash.slice(0, 12)

  if (count > 500) {
    process.stderr.write(
      `note: ${count} schemas; worker-thread AST walk deferred to 1.1 (v0.1 runs single-threaded)\n`,
    )
  }

  if (check) {
    if (!(await pathExists(outPath))) {
      process.stderr.write(
        `drift: ${outPath} does not exist; run \`barkpark codegen\` to create it\n`,
      )
      process.exit(1)
      return
    }
    const existing = await readFile(outPath, 'utf8')
    if (existing === generated) {
      process.stdout.write(`codegen: no drift (hash ${shortHash})\n`)
      return
    }
    process.stderr.write(
      `drift: generated output differs from ${outPath}\n${firstDiff(existing, generated)}\n`,
    )
    process.exit(1)
    return
  }

  await mkdir(dirname(outPath), { recursive: true })
  await writeFile(outPath, generated, 'utf8')
  process.stdout.write(
    `generated ${outPath} (${count} schemas, hash ${shortHash})\n`,
  )
}

export async function runCodegen(opts: CodegenOptions = {}): Promise<void> {
  if (!opts.watch) {
    await runOnce(opts)
    return
  }

  const inPath = resolve(opts.in ?? '.barkpark/schema.json')
  const oneShotOpts: CodegenOptions = { ...opts, watch: false }

  await runOnce(oneShotOpts).catch((err: unknown) => {
    process.stderr.write(
      `codegen (initial): ${(err as Error)?.stack ?? String(err)}\n`,
    )
  })

  const handle = startWatch(inPath, () => runOnce(oneShotOpts))
  process.stdout.write(`watching ${inPath} (debounce 200ms)\n`)

  const shutdown = async (): Promise<void> => {
    await handle.close()
    process.exit(0)
  }
  process.on('SIGINT', () => {
    void shutdown()
  })
  process.on('SIGTERM', () => {
    void shutdown()
  })

  // Keep the event loop alive
  await new Promise<void>(() => {
    /* never resolves; SIGINT/SIGTERM exits */
  })
}
