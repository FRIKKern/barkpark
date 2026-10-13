import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { describe, expect, it } from 'vitest'
import { acquireLease, EngineBusyError } from '../src/lease'
import { createRuntimeRecord } from '../src/runtime-record'

const tempDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'engine-lease-'))
// A process id that has exited: spawn a process and wait for it.
const deadPid = () => spawnSync(process.execPath, ['-e', '0']).pid!

describe('acquireLease', () => {
  it('refuses a second owner while the first lives, and allows one after release', () => {
    const file = path.join(tempDir(), 'engine.lock')
    const first = acquireLease(file)
    expect(() => acquireLease(file)).toThrow(EngineBusyError)
    first.release()
    expect(fs.existsSync(file)).toBe(false)
    acquireLease(file).release()
  })

  it('takes over a lease whose process is gone and keeps the old file as evidence', () => {
    const dir = tempDir()
    const file = path.join(dir, 'engine.lock')
    fs.writeFileSync(file, JSON.stringify({ pid: deadPid(), lease: 'old' }))
    const lease = acquireLease(file)
    expect(JSON.parse(fs.readFileSync(file, 'utf8'))).toEqual({ pid: process.pid, lease: lease.id })
    expect(fs.readdirSync(dir).filter(name => name.startsWith('engine.lock.abandoned-'))).toHaveLength(1)
    expect(fs.existsSync(file + '.recovery')).toBe(false)
    lease.release()
  })

  it('refuses while another contender is recovering the same lease', () => {
    const file = path.join(tempDir(), 'engine.lock')
    fs.writeFileSync(file, JSON.stringify({ pid: deadPid(), lease: 'old' }))
    fs.writeFileSync(file + '.recovery', '{}')
    expect(() => acquireLease(file)).toThrow(/recovery/)
  })

  it('refuses a lease file it cannot read rather than removing it', () => {
    const file = path.join(tempDir(), 'engine.lock')
    fs.writeFileSync(file, 'not json')
    expect(() => acquireLease(file)).toThrow(/unreadable/)
    expect(fs.readFileSync(file, 'utf8')).toBe('not json')
  })

  it('will not release a lease that now names another owner', () => {
    const file = path.join(tempDir(), 'engine.lock')
    const lease = acquireLease(file)
    fs.writeFileSync(file, JSON.stringify({ pid: process.pid, lease: 'someone-else' }))
    expect(() => lease.release()).toThrow(/another owner/)
  })
})

describe('runtime record', () => {
  it('stops a leftover server and database proven by pid and start time', async () => {
    const dir = tempDir()
    const stopped: number[] = []
    let dbRunning = true
    const alive = new Set([111, 222])
    const record = createRuntimeRecord(dir, {
      hostPid: 999, startedAt: pid => `t${pid}`, isAlive: pid => alive.has(pid),
      stopGroup: async pid => { stopped.push(pid); alive.delete(pid) },
    })
    // Written by an earlier host (pid 111) that has since died.
    fs.writeFileSync(record.file, JSON.stringify({ version: 1, hostPid: 333, hostStartedAt: 't333', pid: 222, startedAt: 't222', port: 1, pgPort: 2, launchedAt: 'x' }))
    const result = await record.reclaim({ running: async () => dbRunning, stop: async () => { dbRunning = false } })
    expect(result).toEqual({ reclaimed: true, server: true, database: true })
    expect(stopped).toEqual([222])
    expect(fs.existsSync(record.file)).toBe(false)
  })

  it('never signals a recycled process id', async () => {
    const dir = tempDir()
    const stopped: number[] = []
    const record = createRuntimeRecord(dir, { hostPid: 999, startedAt: () => 'later', isAlive: () => true, stopGroup: async pid => { stopped.push(pid) } })
    fs.writeFileSync(record.file, JSON.stringify({ version: 1, hostPid: 333, hostStartedAt: 'earlier', pid: 222, startedAt: 'earlier', port: 1, pgPort: 2, launchedAt: 'x' }))
    await record.reclaim({ running: async () => false, stop: async () => {} })
    expect(stopped).toEqual([])
  })

  it('refuses when the recorded host is still running', async () => {
    const dir = tempDir()
    const record = createRuntimeRecord(dir, { hostPid: 999, startedAt: pid => `t${pid}`, isAlive: () => true })
    fs.writeFileSync(record.file, JSON.stringify({ version: 1, hostPid: 333, hostStartedAt: 't333', pid: null, startedAt: null, port: 1, pgPort: 2, launchedAt: 'x' }))
    await expect(record.reclaim({ running: async () => true, stop: async () => {} })).rejects.toThrow(/another running process/)
  })
})
