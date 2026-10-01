// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

// `barkpark genrate` (a typo), a bare `barkpark` and `barkpark --version` all
// printed nothing and exited 0 — a CI step that mistyped `generate` "passed"
// without writing barkpark.types.ts (stranger walk, 2026-10-01). These run the
// BUILT binary, the one package scripts and the drift gate invoke.

const here = dirname(fileURLToPath(import.meta.url))
const cliPath = resolve(here, '../dist/cli.mjs')
const pkg = JSON.parse(readFileSync(resolve(here, '../package.json'), 'utf8')) as {
  version: string
}

const run = (...args: string[]) => spawnSync('node', [cliPath, ...args], { encoding: 'utf8' })

describe('barkpark CLI: no silent success', () => {
  it('a mistyped command fails and names itself', () => {
    const r = run('genrate')
    expect(r.status).toBe(1)
    expect(r.stderr).toContain('unknown command "genrate"')
  })

  it('no command at all prints the help and fails', () => {
    const r = run()
    expect(r.status).toBe(1)
    expect(r.stdout).toContain('generate')
  })

  it('--version prints the package version', () => {
    const r = run('--version')
    expect(r.status).toBe(0)
    expect(r.stdout).toContain(`barkpark/${pkg.version}`)
  })

  it('--help and a real command still succeed', () => {
    expect(run('--help').status).toBe(0)
    const sp = run('schema-path', 'production')
    expect(sp.status).toBe(0)
    expect(sp.stdout.trim()).toBe('/v1/schemas/production')
  })
})
