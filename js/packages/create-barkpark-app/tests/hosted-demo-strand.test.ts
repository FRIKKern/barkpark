// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdir, mkdtemp, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { applyHostedDemoSafely } from '../src/hosted.js'

/**
 * cca-backlog-hosted-demo-strand: a throw in applyHostedDemo escaped to the
 * top-level catch AFTER the copy finished — the run aborted with a COMPLETE
 * 34-file tree in place, and ensureTargetEmpty then refused every retry.
 *
 * REMEDY (recorded in applyHostedDemoSafely's doc): relieve, not clean up.
 * The tree at that point is finished, usable work; only the hosted-demo
 * post-configuration is missing. So the failure is caught, said out loud with
 * the two manual steps, and the run CONTINUES — nothing is deleted and there
 * is nothing left to retry, so the jam cannot occur.
 *
 * The failure is injected for real: .env.local exists as a DIRECTORY, so the
 * unguarded fs.writeFile inside applyHostedDemo throws EISDIR mid-sequence.
 */
describe('applyHostedDemoSafely — a post-copy failure relieves instead of stranding', () => {
  let dir: string | undefined

  afterEach(async () => {
    vi.restoreAllMocks()
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('happy path: applies the settings and reports true', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-hosted-'))
    await writeFile(join(dir, 'docker-compose.yml'), 'services: {}\n', 'utf8')
    expect(await applyHostedDemoSafely({ targetDir: dir })).toBe(true)
    const env = await stat(join(dir, '.env.local'))
    expect(env.isFile()).toBe(true)
    await expect(stat(join(dir, 'docker-compose.yml'))).rejects.toThrow()
  })

  it('failure: resolves false, warns with the manual steps, deletes NOTHING', async () => {
    dir = await mkdtemp(join(tmpdir(), 'cba-hosted-'))
    // The completed scaffold this run must not destroy.
    await writeFile(join(dir, 'package.json'), '{"name":"my-app"}\n', 'utf8')
    // Injected failure: .env.local as a directory → writeFile throws EISDIR.
    await mkdir(join(dir, '.env.local'))
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Never throws (the old code let this escape and abort the run) …
    await expect(applyHostedDemoSafely({ targetDir: dir })).resolves.toBe(false)

    // … says what failed and how to finish by hand …
    const said = errSpy.mock.calls.map((c) => String(c[0])).join('\n')
    expect(said).toContain('Could not apply --hosted-demo settings')
    expect(said).toContain('scaffold is complete and usable')
    expect(said).toContain('BARKPARK_API_URL=')

    // … and the finished tree is untouched: relieve, never clean up.
    const entries = await readdir(dir)
    expect(entries).toContain('package.json')
  })
})
