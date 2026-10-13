// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// task-9b5a6d8efdfab59e: the hosted demo host (barkpark.dev) does not answer, so
// --hosted-demo refuses before any prompt or file write and exits 1, naming the
// local path. Subprocess harness against dist/index.js, like install-failure-exit.
//
// MUTATION-VALIDITY: set HOSTED_DEMO_AVAILABLE to true in src/constants.ts and the
// exit-code and no-directory asserts go RED.

import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execa } from 'execa'
import { afterEach, describe, expect, it } from 'vitest'

const pkgRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const cli = join(pkgRoot, 'dist', 'index.js')

describe('--hosted-demo while the demo host is unavailable (subprocess)', () => {
  let dir: string | undefined

  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('exits 1 with the local-Barkpark message and writes nothing', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-hosted-demo-'))
    const result = await execa('node', [cli, 'my-app', '--hosted-demo', '-y', '--skip-install', '--skip-git'], {
      cwd: dir,
      reject: false,
    })
    expect(result.exitCode).toBe(1)
    expect(result.stderr).toContain("The hosted demo isn't available yet")
    expect(result.stderr).toContain('bp setup --target local --yes')
    await expect(stat(join(dir, 'my-app'))).rejects.toThrow()
  }, 60_000)

  it('without the flag the scaffold still runs and does not offer the demo', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-hosted-demo-off-'))
    const result = await execa('node', [cli, 'my-app', '-y', '--skip-install', '--skip-git'], {
      cwd: dir,
      reject: false,
    })
    expect(result.exitCode).toBe(0)
    expect((await stat(join(dir, 'my-app'))).isDirectory()).toBe(true)
    expect(result.stdout + result.stderr).not.toContain('Pass --hosted-demo')
  }, 120_000)
})
