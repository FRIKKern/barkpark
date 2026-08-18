import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { ensureTargetEmpty, cleanupPartialScaffold } from '../src/target-dir'

/**
 * Proven against the real binary before this module existed: an EACCES on one
 * template file left 4 of 38 entries on disk, and the immediate retry died with
 * `Target directory "…" is not empty.` — one transient failure permanently
 * blocked the user. These tests pin the cleanup AND its two edges (a symlinked
 * target, a pre-existing empty dir), which a bare recursive rm gets wrong.
 */

let tmp: string

beforeEach(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'cba-target-dir-'))
})

afterEach(async () => {
  await fs.rm(tmp, { recursive: true, force: true })
})

/** What scaffold() does before it throws: create the dir, write some files. */
async function writePartialScaffold(dir: string): Promise<void> {
  await fs.mkdir(path.join(dir, 'app'), { recursive: true })
  await fs.writeFile(path.join(dir, 'package.json'), '{}')
  await fs.writeFile(path.join(dir, 'app', 'page.tsx'), 'export default () => null')
}

describe('ensureTargetEmpty', () => {
  it('refuses a pre-existing non-empty directory and leaves its contents untouched', async () => {
    const target = path.join(tmp, 'my-site')
    await fs.mkdir(target)
    await fs.writeFile(path.join(target, 'PRECIOUS.txt'), 'user data')

    await expect(ensureTargetEmpty(target)).rejects.toThrow(
      `Target directory "${target}" is not empty.`,
    )
    expect(await fs.readFile(path.join(target, 'PRECIOUS.txt'), 'utf8')).toBe('user data')
  })

  it('rejects a target path that exists and is not a directory', async () => {
    const target = path.join(tmp, 'a-file')
    await fs.writeFile(target, 'not a dir')

    await expect(ensureTargetEmpty(target)).rejects.toThrow('exists and is not a directory')
  })

  it('reports createdByRun for an absent path and not for one the user made', async () => {
    const absent = path.join(tmp, 'absent')
    expect(await ensureTargetEmpty(absent)).toEqual({ targetDir: absent, createdByRun: true })

    const preexisting = path.join(tmp, 'preexisting')
    await fs.mkdir(preexisting)
    expect(await ensureTargetEmpty(preexisting)).toEqual({
      targetDir: preexisting,
      createdByRun: false,
    })
  })
})

describe('cleanupPartialScaffold', () => {
  it('clears a half-written scaffold so the retry guard passes again', async () => {
    const target = path.join(tmp, 'my-site')
    const state = await ensureTargetEmpty(target)
    await writePartialScaffold(target)

    // Without the cleanup this is exactly the shipped bug: the retry dies with
    // `Target directory "…" is not empty.`
    await expect(ensureTargetEmpty(target)).rejects.toThrow('is not empty.')

    await cleanupPartialScaffold(state)

    await expect(fs.stat(target)).rejects.toMatchObject({ code: 'ENOENT' })
    await expect(ensureTargetEmpty(target)).resolves.toEqual({
      targetDir: target,
      createdByRun: true,
    })
  })

  it('keeps a symlinked target as a symlink and empties the real directory behind it', async () => {
    const real = path.join(tmp, 'real')
    const link = path.join(tmp, 'my-site')
    await fs.mkdir(real)
    await fs.symlink(real, link)

    const state = await ensureTargetEmpty(link)
    await writePartialScaffold(link)

    await cleanupPartialScaffold(state)

    expect((await fs.lstat(link)).isSymbolicLink()).toBe(true)
    expect(await fs.readdir(real)).toEqual([])
    await expect(ensureTargetEmpty(link)).resolves.toEqual({
      targetDir: link,
      createdByRun: false,
    })
  })

  it('keeps a pre-existing empty directory the user created', async () => {
    const target = path.join(tmp, 'my-site')
    await fs.mkdir(target)

    const state = await ensureTargetEmpty(target)
    await writePartialScaffold(target)

    await cleanupPartialScaffold(state)

    expect((await fs.stat(target)).isDirectory()).toBe(true)
    expect(await fs.readdir(target)).toEqual([])
  })

  it('is a no-op when the scaffold threw before creating anything', async () => {
    const target = path.join(tmp, 'my-site')
    const state = await ensureTargetEmpty(target)

    await expect(cleanupPartialScaffold(state)).resolves.toBeUndefined()
    await expect(fs.stat(target)).rejects.toMatchObject({ code: 'ENOENT' })
  })
})
