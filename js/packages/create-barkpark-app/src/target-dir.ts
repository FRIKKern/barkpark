import { promises as fs } from 'node:fs'
import path from 'node:path'

/**
 * What `ensureTargetEmpty` observed about the target path BEFORE the scaffold
 * touched the filesystem. `cleanupPartialScaffold` needs this to know what it
 * is allowed to delete: only bytes this run wrote, never a path the user owned.
 */
export interface TargetDirState {
  /** Absolute path the scaffold writes into. */
  targetDir: string
  /** True when the path did not exist at guard time — this run creates it. */
  createdByRun: boolean
}

/**
 * Refuse to scaffold into a directory that already holds anything.
 *
 * Runs BEFORE any mkdir/copy, so a pre-existing user project aborts the run
 * untouched. Returns the state the cleanup path needs.
 */
export async function ensureTargetEmpty(targetDir: string): Promise<TargetDirState> {
  try {
    const entries = await fs.readdir(targetDir)
    if (entries.length > 0) {
      throw new Error(`Target directory "${targetDir}" is not empty.`)
    }
    return { targetDir, createdByRun: false }
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code
    if (code === 'ENOENT') return { targetDir, createdByRun: true }
    if (code === 'ENOTDIR')
      throw new Error(`Target path "${targetDir}" exists and is not a directory.`)
    throw err
  }
}

/**
 * Remove what a failed scaffold left behind, so the immediate retry is not
 * blocked by `ensureTargetEmpty` seeing a half-copied tree.
 *
 * Deletes the path itself ONLY when this run created it and it is a real
 * directory. A path the user made (or a symlink to one) keeps existing — only
 * its entries go — because the guard above already proved it was empty, so
 * everything inside it was written by this run and nothing else can be reached.
 */
export async function cleanupPartialScaffold(state: TargetDirState): Promise<void> {
  const { targetDir, createdByRun } = state

  let isSymlink = false
  try {
    isSymlink = (await fs.lstat(targetDir)).isSymbolicLink()
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return
    throw err
  }

  if (createdByRun && !isSymlink) {
    await fs.rm(targetDir, { recursive: true, force: true })
    return
  }

  let entries: string[]
  try {
    entries = await fs.readdir(targetDir)
  } catch (err) {
    // A dangling symlink has nothing inside it to clean.
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') return
    throw err
  }
  for (const entry of entries) {
    await fs.rm(path.join(targetDir, entry), { recursive: true, force: true })
  }
}
