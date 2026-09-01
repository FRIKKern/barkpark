// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { resolveConfig } from '../src/cli'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const cliPath = resolve(here, '../dist/cli.mjs')

/**
 * workspace + project are the two halves of a scoped schema path. Supplying
 * only one silently falls back to the flat /v1/schemas/<dataset> path (see
 * buildSchemaPath's back-compat), which emits types for the wrong, unscoped
 * content model. resolveConfig must reject the half-specified case rather than
 * mis-scope in silence.
 */
describe('resolveConfig — workspace/project must be both-or-neither', () => {
  const base = { dataset: 'd', output: 'o', apiUrl: 'u' }

  it('rejects when only workspace is set', async () => {
    await expect(resolveConfig({ ...base, workspace: 'a' })).rejects.toThrow(
      'workspace and project must be set together',
    )
  })

  it('rejects when only project is set', async () => {
    await expect(resolveConfig({ ...base, project: 'p' })).rejects.toThrow(
      'workspace and project must be set together',
    )
  })

  it('resolves when both are set', async () => {
    await expect(
      resolveConfig({ ...base, workspace: 'a', project: 'p' }),
    ).resolves.toMatchObject({ dataset: 'd', output: 'o', apiUrl: 'u', workspace: 'a', project: 'p' })
  })

  it('resolves when neither is set', async () => {
    await expect(resolveConfig({ ...base })).resolves.toMatchObject({
      dataset: 'd',
      output: 'o',
      apiUrl: 'u',
    })
  })
})

/**
 * `schema-path` shares the same both-or-neither footgun as `generate`: a lone
 * --workspace (or --project) silently prints the flat /v1/schemas/<dataset>
 * path. The command must reject the half-specified case rather than print a
 * mis-scoped path.
 */
describe('schema-path — workspace/project must be both-or-neither', () => {
  it('exits 1 with the both-or-neither message when only --workspace is set', async () => {
    await expect(
      exec('node', [cliPath, 'schema-path', 'production', '--workspace', 'acme']),
    ).rejects.toMatchObject({
      code: 1,
      stderr: expect.stringContaining('workspace and project must be set together'),
    })
  })

  it('exits 1 when only --project is set', async () => {
    await expect(
      exec('node', [cliPath, 'schema-path', 'production', '--project', 'blog']),
    ).rejects.toMatchObject({ code: 1 })
  })

  it('prints the scoped path when both flags are set', async () => {
    const { stdout } = await exec('node', [
      cliPath,
      'schema-path',
      'production',
      '--workspace',
      'acme',
      '--project',
      'blog',
    ])
    expect(stdout.trim()).toBe('/w/acme/p/blog/v1/schemas/production')
  })

  it('prints the flat path when neither flag is set', async () => {
    const { stdout } = await exec('node', [cliPath, 'schema-path', 'production'])
    expect(stdout.trim()).toBe('/v1/schemas/production')
  })
})
