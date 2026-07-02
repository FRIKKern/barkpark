// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { execFile } from 'node:child_process'
import { readFileSync, mkdtempSync, readFileSync as read } from 'node:fs'
import { promisify } from 'node:util'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { dirname, resolve, join } from 'node:path'
import { beforeAll, describe, expect, it } from 'vitest'
import { generateTypes, schemaEnvelopeSchema } from '../src/index'
import type { BarkparkSchemaJson } from '../src/index'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const fixturePath = resolve(here, 'fixtures/production-schema.json')
const cliPath = resolve(here, '../dist/cli.mjs')

let envelope: BarkparkSchemaJson
let expected: string

beforeAll(async () => {
  const raw = JSON.parse(readFileSync(fixturePath, 'utf8')) as unknown
  envelope = schemaEnvelopeSchema.parse(raw)
  expected = await generateTypes(envelope, { dataset: 'production' })
})

/**
 * The `--from` path is network-free: it reads + zod-parses a local JSON file
 * instead of calling fetchSchema. This is exactly what the CI drift gate runs,
 * so the test exercises the built binary the gate invokes (`barkpark generate
 * --from <fixture> --output <tmp>`) — never the live API.
 */
describe('generate --from <file> (network-free)', () => {
  it('reads a local schema file and writes byte-identical output to generateTypes', async () => {
    const out = join(mkdtempSync(join(tmpdir(), 'bp-codegen-')), 'barkpark.types.ts')
    await exec('node', [
      cliPath,
      'generate',
      '--from',
      fixturePath,
      '--dataset',
      'production',
      '--output',
      out,
    ])
    expect(read(out, 'utf8')).toBe(expected)
  })

  it('reads output + dataset from --config when the flags are omitted', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'bp-codegen-'))
    const out = join(dir, 'barkpark.types.ts')
    const configPath = join(dir, 'barkpark.config.mjs')
    const { writeFileSync } = await import('node:fs')
    writeFileSync(
      configPath,
      `export default ${JSON.stringify({ output: out, dataset: 'production' })}\n`,
      'utf8',
    )
    await exec('node', [cliPath, 'generate', '--from', fixturePath, '--config', configPath])
    expect(read(out, 'utf8')).toBe(expected)
  })

  it('accepts --schema as an alias for --from', async () => {
    const out = join(mkdtempSync(join(tmpdir(), 'bp-codegen-')), 'barkpark.types.ts')
    await exec('node', [
      cliPath,
      'generate',
      '--schema',
      fixturePath,
      '--dataset',
      'production',
      '--output',
      out,
    ])
    expect(read(out, 'utf8')).toBe(expected)
  })

  it('never reaches the network: succeeds with no API URL / token in the env', async () => {
    const out = join(mkdtempSync(join(tmpdir(), 'bp-codegen-')), 'barkpark.types.ts')
    const { stderr } = await exec(
      'node',
      [cliPath, 'generate', '--from', fixturePath, '--dataset', 'production', '--output', out],
      { env: { ...process.env, BARKPARK_API_URL: '', BARKPARK_TOKEN: '' } },
    )
    expect(stderr).toBe('')
    expect(read(out, 'utf8')).toBe(expected)
  })

  it('fails loudly on a malformed schema file', async () => {
    const badDir = mkdtempSync(join(tmpdir(), 'bp-codegen-'))
    const badFile = join(badDir, 'bad.json')
    const out = join(badDir, 'barkpark.types.ts')
    // Write a JSON that is valid JSON but not a schema envelope.
    const { writeFileSync } = await import('node:fs')
    writeFileSync(badFile, JSON.stringify({ not: 'a schema' }), 'utf8')
    await expect(
      exec('node', [
        cliPath,
        'generate',
        '--from',
        badFile,
        '--dataset',
        'production',
        '--output',
        out,
      ]),
    ).rejects.toMatchObject({ code: 1 })
  })
})
