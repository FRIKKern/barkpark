// One owner per dataDir. The lease is a file created exclusively; a second start
// on the same folder is refused while the owner's process lives. A lease whose
// process is gone is moved aside (kept as evidence) and taken over. Recovery is
// serialized by a second exclusive file, so two contenders that both read the
// same stale owner cannot both take over.
//
// Lifted from Barkdown's app/main/file-lease.js (ee50133b), plain path only.
import fs from 'node:fs'
import crypto from 'node:crypto'

export class EngineBusyError extends Error {
  readonly code = 'engine_busy'
}

export interface Lease {
  readonly id: string
  readonly file: string
  /** Throws when the file no longer names this lease. */
  assertOwned(): void
  /** Removes the lease file. Refuses when another owner holds it. */
  release(): void
}

export interface LeaseDeps {
  pid?: number
  /** Whether a process id is running. Defaults to signal 0. */
  isAlive?: (pid: number) => boolean
}

export function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM'
  }
}

interface Owner { pid: number; lease: string }

function readOwner(file: string): Owner {
  return JSON.parse(fs.readFileSync(file, 'utf8')) as Owner
}

export function acquireLease(file: string, deps: LeaseDeps = {}): Lease {
  const pid = deps.pid ?? process.pid
  const isAlive = deps.isAlive ?? processAlive
  const id = crypto.randomUUID()
  const busy = () => new EngineBusyError(`Another process owns this Barkpark data folder (${file}). Stop it first; nothing was changed.`)
  const open = () => fs.openSync(file, 'wx', 0o600)
  let fd: number | undefined
  try {
    fd = open()
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    const recovery = file + '.recovery'
    let guard: number
    try {
      guard = fs.openSync(recovery, 'wx', 0o600)
    } catch (failure) {
      if ((failure as NodeJS.ErrnoException).code === 'EEXIST') {
        throw new EngineBusyError(`Lease recovery for ${file} is already under way. If no process is recovering it, remove ${recovery}.`)
      }
      throw failure
    }
    try {
      fs.writeFileSync(guard, JSON.stringify({ pid }))
      let owner: Owner | undefined
      try {
        owner = readOwner(file)
      } catch (failure) {
        if ((failure as NodeJS.ErrnoException).code !== 'ENOENT') throw new Error(`The lease file ${file} is unreadable; inspect it before removing it.`)
        // The owner released between our refusal and this read: try once more.
        try { fd = open() } catch (raced) { if ((raced as NodeJS.ErrnoException).code === 'EEXIST') throw busy(); throw raced }
      }
      if (fd === undefined) {
        if (!owner || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw new Error(`The lease file ${file} names no valid owner; inspect it before removing it.`)
        if (isAlive(owner.pid)) throw busy()
        fs.renameSync(file, `${file}.abandoned-${crypto.randomUUID()}`)
        try { fd = open() } catch (raced) { if ((raced as NodeJS.ErrnoException).code === 'EEXIST') throw busy(); throw raced }
      }
    } finally {
      fs.closeSync(guard)
      fs.unlinkSync(recovery)
    }
  }
  try {
    fs.writeFileSync(fd, JSON.stringify({ pid, lease: id }))
    fs.fsyncSync(fd)
  } finally {
    fs.closeSync(fd)
  }
  let released = false
  const assertOwned = () => {
    if (released) throw new Error('This lease was released.')
    let owner: Owner
    try { owner = readOwner(file) } catch { throw new Error(`The lease file ${file} changed or disappeared.`) }
    if (owner.lease !== id || owner.pid !== pid) throw new Error(`The lease file ${file} now names another owner.`)
  }
  return Object.freeze({
    id,
    file,
    assertOwned,
    release() {
      if (released) return
      assertOwned()
      fs.unlinkSync(file)
      released = true
    },
  })
}
