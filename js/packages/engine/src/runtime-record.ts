// The server and the database outlive a host process that dies: the server leads its
// own process group and Postgres runs as a daemon. The record written at launch lets
// the next owner of the dataDir prove a leftover is its own and stop it before it
// starts again. Proof is the process id together with its start time, so a recycled
// id is never signalled. The database is addressed only through its data directory.
//
// Lifted from Barkdown's app/main/runtime-orphan.js (ee50133b). The platform
// differences (start time, stopping a tree) live in platform.ts.
import fs from 'node:fs'
import path from 'node:path'
import { processStartedAt, signalTree } from './platform'
import { processAlive } from './lease'

export const RECORD = 'runtime-process.json'

export interface RuntimeRecordValue {
  version: 1
  hostPid: number
  hostStartedAt: string
  pid: number | null
  startedAt: string | null
  port: number
  pgPort: number
  launchedAt: string
}

export interface RuntimeRecordDeps {
  hostPid?: number
  startedAt?: (pid: number) => string
  isAlive?: (pid: number) => boolean
  stopGroup?: (pid: number) => Promise<void>
  now?: () => string
}

export interface ReclaimResult { reclaimed: boolean; server: boolean; database: boolean }

export { processStartedAt }

const sleep = (ms: number) => new Promise<void>(resolve => setTimeout(resolve, ms))

/** Ask the tree to stop, wait up to 10 s, then force it and wait up to 5 s. */
export async function stopProcessGroup(pid: number, isAlive: (pid: number) => boolean = processAlive): Promise<void> {
  signalTree(pid, false)
  for (let waited = 0; waited < 10_000 && isAlive(pid); waited += 200) await sleep(200)
  if (isAlive(pid)) {
    signalTree(pid, true)
    for (let waited = 0; waited < 5_000 && isAlive(pid); waited += 200) await sleep(200)
  }
}

export function createRuntimeRecord(dataDir: string, deps: RuntimeRecordDeps = {}) {
  if (!path.isAbsolute(dataDir)) throw new TypeError('The runtime record needs an absolute dataDir.')
  const hostPid = deps.hostPid ?? process.pid
  const startedAt = deps.startedAt ?? processStartedAt
  const isAlive = deps.isAlive ?? processAlive
  const stopGroup = deps.stopGroup ?? ((pid: number) => stopProcessGroup(pid, isAlive))
  const now = deps.now ?? (() => new Date().toISOString())
  const file = path.join(dataDir, RECORD)

  const valid = (v: RuntimeRecordValue | null): v is RuntimeRecordValue =>
    !!v && v.version === 1 && Number.isSafeInteger(v.hostPid) && v.hostPid > 0 && typeof v.hostStartedAt === 'string' &&
    (v.pid === null || (Number.isSafeInteger(v.pid) && v.pid > 1 && typeof v.startedAt === 'string'))

  function read(): RuntimeRecordValue | null {
    let value: RuntimeRecordValue | null
    try {
      value = JSON.parse(fs.readFileSync(file, 'utf8')) as RuntimeRecordValue
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
      throw new Error(`The runtime record ${file} is unreadable; nothing was stopped.`)
    }
    if (!valid(value)) throw new Error(`The runtime record ${file} is invalid; nothing was stopped.`)
    return value
  }

  function write({ pid = null, port, pgPort }: { pid?: number | null; port: number; pgPort: number }): RuntimeRecordValue {
    const value: RuntimeRecordValue = {
      version: 1, hostPid, hostStartedAt: startedAt(hostPid), pid, startedAt: pid === null ? null : startedAt(pid), port, pgPort, launchedAt: now(),
    }
    const temporary = `${file}.${process.pid}.tmp`
    fs.writeFileSync(temporary, JSON.stringify(value, null, 2) + '\n')
    fs.renameSync(temporary, file)
    return value
  }

  function clear(): void {
    try { fs.unlinkSync(file) } catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error }
  }

  const same = (pid: number, started: string | null) => Boolean(started) && isAlive(pid) && startedAt(pid) === started

  /** Stop what an earlier owner of this dataDir left running. */
  async function reclaim(db: { running: () => Promise<boolean>; stop: () => Promise<void> }): Promise<ReclaimResult> {
    const record = read()
    if (!record) return { reclaimed: false, server: false, database: false }
    if (record.hostPid !== hostPid && same(record.hostPid, record.hostStartedAt)) {
      throw Object.assign(new Error('This data folder\'s server belongs to another running process. Nothing was stopped.'), { code: 'engine_busy' })
    }
    let server = false
    let database = false
    if (record.pid !== null && same(record.pid, record.startedAt)) {
      await stopGroup(record.pid)
      if (same(record.pid, record.startedAt)) throw new Error('A server left by an earlier owner did not stop. Nothing else was changed.')
      server = true
    }
    if (await db.running()) {
      await db.stop()
      if (await db.running()) throw new Error('A database left by an earlier owner did not stop. Nothing else was changed.')
      database = true
    }
    clear()
    return { reclaimed: server || database, server, database }
  }

  return Object.freeze({ file, read, write, clear, reclaim })
}

export type RuntimeRecord = ReturnType<typeof createRuntimeRecord>
