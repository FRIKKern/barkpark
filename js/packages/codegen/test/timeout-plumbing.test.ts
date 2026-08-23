// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { resolveConfig } from '../src/cli'

/**
 * cca-backlog-timeout-cli-plumbing: fetchSchema gained timeoutMs (30s default,
 * 0 disables) in wave 1, but nothing could SET it — the wave fenced cli.ts to
 * the --watch slice. This suite pins the three advertised sources, one test
 * each, plus their precedence (flag > config file > env, mirroring apiUrl) and
 * the loud rejection of a mistyped value.
 */

const BASE = { dataset: 'production', output: 'o.ts', apiUrl: 'http://localhost:4000' }

function withEnv<T>(key: string, value: string | undefined, fn: () => Promise<T>): Promise<T> {
  const saved = process.env[key]
  if (value === undefined) delete process.env[key]
  else process.env[key] = value
  return fn().finally(() => {
    if (saved === undefined) delete process.env[key]
    else process.env[key] = saved
  })
}

describe('schema-fetch timeout is settable from flag, config file and environment', () => {
  let dir: string | undefined

  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('CLI flag: --timeout 5000 lands as timeoutMs 5000 (and 0 disables)', async () => {
    expect(await resolveConfig({ ...BASE, timeout: '5000' })).toMatchObject({ timeoutMs: 5000 })
    expect(await resolveConfig({ ...BASE, timeout: '0' })).toMatchObject({ timeoutMs: 0 })
  })

  it('config file: timeoutMs in barkpark.config lands on the resolved config', async () => {
    dir = await mkdtemp(join(tmpdir(), 'bp-codegen-timeout-'))
    const configPath = join(dir, 'barkpark.config.mjs')
    await writeFile(
      configPath,
      "export default { dataset: 'production', output: 'o.ts', apiUrl: 'http://localhost:4000', timeoutMs: 120000 }\n",
      'utf8',
    )
    expect(await resolveConfig({ config: configPath })).toMatchObject({ timeoutMs: 120_000 })
  })

  it('environment: BARKPARK_SCHEMA_TIMEOUT_MS applies when nothing stronger set it', () =>
    withEnv('BARKPARK_SCHEMA_TIMEOUT_MS', '45000', async () => {
      expect(await resolveConfig({ ...BASE })).toMatchObject({ timeoutMs: 45_000 })
    }))

  it('precedence mirrors apiUrl: flag > config file > environment', async () => {
    dir = await mkdtemp(join(tmpdir(), 'bp-codegen-timeout-'))
    const configPath = join(dir, 'barkpark.config.mjs')
    await writeFile(
      configPath,
      "export default { dataset: 'production', output: 'o.ts', apiUrl: 'http://localhost:4000', timeoutMs: 2000 }\n",
      'utf8',
    )
    await withEnv('BARKPARK_SCHEMA_TIMEOUT_MS', '9000', async () => {
      // env loses to the config file…
      expect(await resolveConfig({ config: configPath })).toMatchObject({ timeoutMs: 2000 })
      // …and both lose to the flag.
      expect(await resolveConfig({ config: configPath, timeout: '1' })).toMatchObject({
        timeoutMs: 1,
      })
    })
  })

  it('a mistyped deadline fails LOUD instead of silently becoming the default', async () => {
    await expect(resolveConfig({ ...BASE, timeout: 'fast' })).rejects.toThrow(/Invalid --timeout/)
    await expect(resolveConfig({ ...BASE, timeout: '-1' })).rejects.toThrow(/Invalid --timeout/)
    await withEnv('BARKPARK_SCHEMA_TIMEOUT_MS', 'soon', async () => {
      await expect(resolveConfig({ ...BASE })).rejects.toThrow(/Invalid BARKPARK_SCHEMA_TIMEOUT_MS/)
    })
  })
})
