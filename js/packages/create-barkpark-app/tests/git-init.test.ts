// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { execa } from 'execa'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { runGitInit } from '../src/post-install.js'

/**
 * cca-backlog-git-init-silent: runGitInit wrapped init/add/commit in a bare
 * `catch { // non-fatal }` — a failure mid-sequence (the measured repro: a
 * global commit.gpgsign=true with gpg.program=/bin/false, a config real
 * developers carry) left a half-initialised .git (files staged, zero commits)
 * and told the user NOTHING. Now: one yellow warning mirroring the
 * dependency-install failure path, and the .git THIS run created is removed
 * (create-next-app precedent) — while a pre-existing repository is left alone.
 *
 * The failing git is injected via GIT_CONFIG_GLOBAL (runGitInit spreads
 * process.env into the commit's env, and init/add inherit it), pointing at a
 * config whose signer is /bin/false — commit exits 128 after init and add
 * have already succeeded, which is exactly the stranding sequence.
 */

const exists = (p: string) =>
  stat(p).then(
    () => true,
    () => false,
  )

async function withFailingGit<T>(dir: string, fn: () => Promise<T>): Promise<T> {
  const cfg = join(dir, 'failing-gitconfig')
  await writeFile(cfg, '[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = /bin/false\n', 'utf8')
  const saved = process.env.GIT_CONFIG_GLOBAL
  process.env.GIT_CONFIG_GLOBAL = cfg
  try {
    return await fn()
  } finally {
    if (saved === undefined) delete process.env.GIT_CONFIG_GLOBAL
    else process.env.GIT_CONFIG_GLOBAL = saved
  }
}

describe('runGitInit — a failing git warns and leaves no half-initialised .git', () => {
  let dir: string | undefined

  afterEach(async () => {
    vi.restoreAllMocks()
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('happy path: initialises a repo with the initial commit', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-git-'))
    await writeFile(join(dir, 'a.txt'), 'hello\n', 'utf8')
    await runGitInit(dir)
    expect(await exists(join(dir, '.git'))).toBe(true)
    const { stdout } = await execa('git', ['log', '--oneline'], { cwd: dir })
    expect(stdout).toContain('initial commit from create-barkpark-app')
  })

  it('commit failure: prints the warning and removes the .git this run created', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-git-'))
    await writeFile(join(dir, 'a.txt'), 'hello\n', 'utf8')
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    await withFailingGit(dir, () => runGitInit(dir!))

    // No stranded half-repo: the .git created by this run is gone…
    expect(await exists(join(dir, '.git'))).toBe(false)
    // …the user's files are intact…
    expect(await exists(join(dir, 'a.txt'))).toBe(true)
    // …and the failure was SAID, with the recovery command (the old code's
    // bare catch printed nothing — this pair of assertions is what reds it).
    const said = errSpy.mock.calls.map((c) => String(c[0])).join('\n')
    expect(said).toContain('git init failed:')
    expect(said).toContain('git init && git add -A && git commit')
  })

  it('never deletes a PRE-EXISTING repository on failure', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-git-'))
    await writeFile(join(dir, 'a.txt'), 'hello\n', 'utf8')
    // A real repo with real history exists before create-barkpark-app runs.
    await runGitInit(dir)
    const { stdout: before } = await execa('git', ['log', '--oneline'], { cwd: dir })
    expect(before).not.toBe('')

    vi.spyOn(console, 'error').mockImplementation(() => {})
    await writeFile(join(dir, 'b.txt'), 'more\n', 'utf8')
    await withFailingGit(dir, () => runGitInit(dir!))

    // Warned, but the existing history is untouched.
    expect(await exists(join(dir, '.git'))).toBe(true)
    const { stdout: after } = await execa('git', ['log', '--oneline'], { cwd: dir })
    expect(after).toBe(before)
  })
})
