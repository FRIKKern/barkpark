// Boots a real engine folder. Runs only when BARKPARK_ENGINE_RELEASE names one
// (built by scripts/engine/build-release.mjs with --add-postgres); skipped otherwise.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { afterAll, describe, expect, it } from 'vitest'
import { startBarkpark, EngineBusyError, type Barkpark } from '../src/index'

const release = process.env.BARKPARK_ENGINE_RELEASE
const filesUnder = (dir: string): string[] => fs.readdirSync(dir, { withFileTypes: true })
  .flatMap(e => e.isDirectory() ? filesUnder(path.join(dir, e.name)) : [path.join(dir, e.name)])

describe.skipIf(!release)('startBarkpark against a built release', () => {
  const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'barkpark-engine-it-'))
  const running: Barkpark[] = []
  afterAll(async () => { for (const bp of running) await bp.stop().catch(() => {}) })

  const statusOf = async (bp: Barkpark) => {
    const response = await fetch(`${bp.url}/status.json`, { headers: { authorization: `Bearer ${bp.token}` } })
    expect(response.status).toBe(200)
    return await response.json() as { commit: string; shape: string | null; components: { name: string; status: string }[] }
  }
  const whoami = (bp: Barkpark, token?: string) =>
    fetch(`${bp.url}/v1/tokens/current`, { headers: token ? { authorization: `Bearer ${token}` } : {} })

  it('boots, refuses a second owner, stops, restarts without reseeding, and stops', async () => {
    const plugins = ['bulldocs']
    let t0 = Date.now()
    const first = await startBarkpark({ dataDir, plugins, release: release! })
    running.push(first)
    const firstBootMs = Date.now() - t0
    expect(first.url).toBe(`http://127.0.0.1:${first.port}`)
    expect(first.token).toMatch(/^bp_admin_/)

    const status = await statusOf(first)
    for (const name of ['database', 'migrations', 'plugins']) {
      expect(status.components.find(c => c.name === name)?.status).toBe('operational')
    }
    expect(first.commit.startsWith(status.commit)).toBe(true)
    expect(status.shape).toBe('app')

    // The returned token is a working admin token; no token is refused.
    const me = await whoami(first, first.token)
    expect(me.status).toBe(200)
    expect(JSON.stringify(await me.json())).toContain('admin')
    expect((await whoami(first)).status).toBe(401)

    // The lease refuses a second owner of the same dataDir.
    await expect(startBarkpark({ dataDir, plugins, release: release! })).rejects.toThrow(EngineBusyError)
    expect((await statusOf(first)).components.length).toBeGreaterThan(0)

    const seededAt = fs.statSync(path.join(dataDir, 'seeded')).mtimeMs
    await first.stop()
    expect(first.status().phase).toBe('stopped')
    expect(fs.existsSync(path.join(dataDir, 'engine.lock'))).toBe(false)
    const pgStatus = spawnSync(path.join(release!, 'postgres', 'bin', 'pg_ctl'), ['-D', path.join(dataDir, 'pgdata'), 'status'])
    expect(pgStatus.status).toBe(3) // pg_ctl: no server running
    await expect(fetch(`${first.url}/status.json`)).rejects.toThrow()

    // A host that died left its lease behind: the next start recovers it.
    const dead = spawnSync(process.execPath, ['-e', '0']).pid!
    fs.writeFileSync(path.join(dataDir, 'engine.lock'), JSON.stringify({ pid: dead, lease: 'crashed-host' }))

    t0 = Date.now()
    const second = await startBarkpark({ dataDir, plugins, release: release! })
    running.push(second)
    const restartMs = Date.now() - t0
    expect(second.token).toBe(first.token)
    expect(second.port).toBe(first.port)
    expect(fs.statSync(path.join(dataDir, 'seeded')).mtimeMs).toBe(seededAt)
    expect((await whoami(second, second.token)).status).toBe(200)
    expect(fs.readdirSync(dataDir).some(name => name.startsWith('engine.lock.abandoned-'))).toBe(true)

    const logs = filesUnder(path.join(dataDir, 'logs')).map(file => fs.readFileSync(file, 'utf8')).join('\n')
    expect(logs.match(/Admin token installed from BARKPARK_SEED_ADMIN_TOKEN/g)).toHaveLength(1)
    expect(logs).not.toContain(first.token)
    const { pgPassword } = JSON.parse(fs.readFileSync(path.join(dataDir, 'secrets.json'), 'utf8')) as { pgPassword: string }
    expect(logs).not.toContain(pgPassword)

    await second.stop()
    expect(fs.existsSync(path.join(dataDir, 'runtime-process.json'))).toBe(false)
    // CI and the local proof read the timings from this file.
    const report = JSON.stringify({ firstBootMs, restartMs, commit: second.commit }, null, 2)
    if (process.env.BARKPARK_ENGINE_REPORT) fs.writeFileSync(process.env.BARKPARK_ENGINE_REPORT, report + '\n')
    // Kept on failure for diagnosis; removed once every check passed.
    fs.rmSync(dataDir, { recursive: true, force: true })
  }, 20 * 60_000)
})
