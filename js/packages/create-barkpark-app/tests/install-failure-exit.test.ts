// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// cca-backlog-install-exit-code: a dependency install the USER ASKED FOR that
// fails must exit 1 — `create-barkpark-app x -y && cd x && npm test` must not
// sail on past a half-installed tree — while the finished scaffold stays on
// disk and the outro says "Done, with warnings." instead of a green "Done."
// that contradicts the yellow errors.
//
// The failure is injected for real: a fake `bun` binary that always exits 7 is
// prepended to PATH and npm_config_user_agent selects bun, so runInstall's
// execa call genuinely fails inside the built CLI (main() runs at module load,
// so this is a subprocess harness against dist/index.js — the same dist-first
// convention rsc-chunk tests use in @barkpark/react).
//
// MUTATION-VALIDITY: revert index.ts to `return 0` after a failed install and
// the exit-code assert goes RED; restore and it re-greens.

import { chmod, mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { delimiter, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execa } from 'execa'
import { afterEach, describe, expect, it } from 'vitest'

const pkgRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const cli = join(pkgRoot, 'dist', 'index.js')

describe('install failure exit code (subprocess)', () => {
  let dir: string | undefined

  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('a failed install the user asked for exits 1, keeps the tree, says "Done, with warnings."', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-install-fail-'))
    // Fake package manager: always fails loudly.
    const bin = join(dir, 'bin')
    await mkdir(bin)
    await writeFile(join(bin, 'bun'), '#!/bin/sh\necho "boom: simulated install failure" >&2\nexit 7\n')
    await chmod(join(bin, 'bun'), 0o755)

    const res = await execa(process.execPath, [cli, 'my-app', '-y', '--skip-git'], {
      cwd: dir,
      reject: false,
      env: {
        ...process.env,
        PATH: `${bin}${delimiter}${process.env.PATH ?? ''}`,
        npm_config_user_agent: 'bun/1.2.0 (test harness)',
        npm_execpath: '',
      },
    })
    const out = res.stdout + '\n' + res.stderr

    // The decision under test: an asked-for install that failed is a non-zero exit.
    expect(res.exitCode).toBe(1)
    // The failure is said out loud with the manual remedy…
    expect(out).toContain('Dependency install failed')
    expect(out).toContain('bun install')
    // …the tone matches: warnings, not a clean green "Done."
    expect(out).toContain('Done, with warnings.')
    // …and the scaffold is finished, usable work — nothing was deleted.
    const pkg = await stat(join(dir, 'my-app', 'package.json'))
    expect(pkg.isFile()).toBe(true)
  }, 30_000)

  it('--skip-install (no install asked for) still exits 0', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-install-skip-'))
    const res = await execa(process.execPath, [cli, 'my-app', '-y', '--skip-install', '--skip-git'], {
      cwd: dir,
      reject: false,
      env: { ...process.env, npm_config_user_agent: 'npm/10.0.0 (test harness)' },
    })
    expect(res.exitCode).toBe(0)
    expect(res.stdout + res.stderr).toContain('Done.')
  }, 30_000)
})
