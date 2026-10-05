// startBarkpark: run a Barkpark release and a private Postgres for one dataDir.
//
// One boot: reclaim anything an earlier owner left running, create the cluster on
// first use (password auth, 127.0.0.1 only), start it with pg_ctl, create the
// database, run the release's migrations, seed once with the clean profile and a
// generated admin token, then start the server as its own process group and wait
// for /status.json to report the database, migrations and plugins as operational.
// A failed boot is stopped and retried a bounded number of times. Once ready, a
// health check runs on an interval; three misses in a row restart the server and
// database, inside the same retry budget.
//
// Lifted from Barkdown's app/main/local-barkpark-source.js and local-barkpark.js
// (ee50133b), packaged-release path only, without Barkdown's profiles.
import fs from 'node:fs'
import net from 'node:net'
import path from 'node:path'
import { spawn, execFile, type ChildProcess } from 'node:child_process'
import { normalizeOptions, type EngineOptions, type StartBarkparkOptions } from './options'
import { acquireLease, type Lease } from './lease'
import { createRuntimeRecord, stopProcessGroup, type RuntimeRecord } from './runtime-record'
import { loadOrCreateSecrets, releaseKeys, redactor, type EngineSecrets } from './secrets'
import { resolveRelease, type ResolvedRelease } from './release'

export type EnginePhase = 'starting' | 'ready' | 'recovering' | 'stopping' | 'stopped' | 'failed'

export interface EngineStatus {
  phase: EnginePhase
  /** Restarts used out of the retry budget. */
  attempts: number
  error: string | null
}

/** What startBarkpark returns once the server answers. */
export interface Barkpark {
  /** http://127.0.0.1:<port> */
  readonly url: string
  /** Admin token seeded on the first start of this dataDir. Keep it out of logs. */
  readonly token: string
  readonly port: number
  readonly dataDir: string
  /** The Barkpark commit the release was built from. */
  readonly commit: string
  status(): EngineStatus
  /** Stop the server and the database, then release the dataDir. */
  stop(): Promise<void>
}

const SYSTEM_PATH = '/usr/bin:/bin:/usr/sbin:/sbin'
const DATABASE = 'barkpark'
const sleep = (ms: number, signal?: AbortSignal) => new Promise<void>((resolve, reject) => {
  const timer = setTimeout(resolve, ms)
  signal?.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason as Error) }, { once: true })
})

function freePort(port = 0): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', () => reject(new Error(`Port ${port} on 127.0.0.1 is in use.`)))
    server.listen(port, '127.0.0.1', () => {
      const address = server.address()
      server.close(() => resolve(typeof address === 'object' && address ? address.port : port))
    })
  })
}

interface RunResult { stdout: string; stderr: string }
function run(file: string, args: string[], options: { env: NodeJS.ProcessEnv; timeout: number; signal?: AbortSignal }): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    execFile(file, args, { env: options.env, timeout: options.timeout, maxBuffer: 16 * 1024 * 1024, ...(options.signal ? { signal: options.signal } : {}) }, (error, stdout, stderr) => {
      if (error) reject(Object.assign(error, { stdout: String(stdout), stderr: String(stderr) }))
      else resolve({ stdout: String(stdout), stderr: String(stderr) })
    })
  })
}

class Engine {
  readonly options: EngineOptions
  readonly release: ResolvedRelease
  readonly dataDir: string
  private lease: Lease | null = null
  private secrets: EngineSecrets | null = null
  private redact: (text: string) => string = text => text
  private readonly record: RuntimeRecord
  private readonly pgData: string
  private readonly logDir: string
  private child: ChildProcess | null = null
  private childError: string | null = null
  private pgOwned = false
  private pgPort = 0
  port = 0
  private state: EngineStatus = { phase: 'stopped', attempts: 0, error: null }
  private abort: AbortController | null = null
  private operation: Promise<unknown> | null = null
  private timer: NodeJS.Timeout | null = null
  private missed = 0

  constructor(options: EngineOptions) {
    this.options = options
    this.release = resolveRelease(options.release)
    this.dataDir = options.dataDir
    this.pgData = path.join(this.dataDir, 'pgdata')
    this.logDir = path.join(this.dataDir, 'logs')
    this.record = createRuntimeRecord(this.dataDir)
  }

  get url(): string { return `http://127.0.0.1:${this.port}` }
  get token(): string { return this.secrets?.adminToken ?? '' }
  status(): EngineStatus { return { ...this.state } }
  private update(phase: EnginePhase, error: string | null = null) { this.state = { ...this.state, phase, error } }

  private log(name: 'server.log' | 'engine.log', text: string) {
    if (text) fs.appendFileSync(path.join(this.logDir, name), this.redact(text))
  }

  private localeEnv(): NodeJS.ProcessEnv {
    const locale = process.platform === 'darwin' ? 'en_US.UTF-8' : 'C.UTF-8'
    return { LANG: locale, LC_ALL: locale }
  }

  private async pg(tool: string, args: string[], timeout = 30_000, signal?: AbortSignal): Promise<RunResult> {
    const env = { PATH: SYSTEM_PATH, ...this.localeEnv(), PGPASSWORD: this.secrets?.pgPassword ?? '' }
    try {
      return await run(path.join(this.release.pgBin, tool), args, { env, timeout, ...(signal ? { signal } : {}) })
    } catch (error) {
      const e = error as Error & { stdout?: string; stderr?: string }
      throw new Error(`${tool} failed${signal?.aborted ? ' (cancelled)' : ''}: ${this.redact(String(e.stderr || e.stdout || e.message)).slice(-1500)}`)
    }
  }

  private pgRunning(): Promise<boolean> {
    if (!fs.existsSync(path.join(this.pgData, 'PG_VERSION'))) return Promise.resolve(false)
    return this.pg('pg_ctl', ['-D', this.pgData, 'status']).then(() => true, () => false)
  }

  private async stopPg(): Promise<void> {
    try {
      await this.pg('pg_ctl', ['-D', this.pgData, '-m', 'fast', '-w', '-t', '20', 'stop'])
    } catch {
      // A stopped cluster needs nothing; a wedged one gets pg_ctl's immediate stop of this data directory only.
      if (await this.pgRunning()) await this.pg('pg_ctl', ['-D', this.pgData, '-m', 'immediate', '-w', '-t', '20', 'stop'])
    }
  }

  private at(): string[] { return ['-h', '127.0.0.1', '-p', String(this.pgPort), '-U', 'postgres'] }

  // ── Ownership ─────────────────────────────────────────────────────────────

  acquire(): void {
    fs.mkdirSync(this.dataDir, { recursive: true, mode: 0o700 })
    this.lease = acquireLease(path.join(this.dataDir, 'engine.lock'))
    try {
      for (const dir of [this.logDir, 'media', 'indx', 'bundles', 'tmp', 'home']) fs.mkdirSync(path.resolve(this.dataDir, dir), { recursive: true })
      const secrets = loadOrCreateSecrets(this.dataDir)
      if (secrets.created && fs.existsSync(path.join(this.pgData, 'PG_VERSION'))) {
        throw new Error(`${this.dataDir} holds a database but no secrets.json; its password and admin token are gone. Nothing was changed.`)
      }
      this.secrets = secrets
      this.redact = redactor([secrets.pgPassword, secrets.adminToken, ...Object.values(releaseKeys(secrets.pgPassword))])
    } catch (error) {
      this.lease.release(); this.lease = null
      throw error
    }
  }

  releaseOwnership(): void {
    if (!this.lease) return
    if (this.pgOwned || (this.child && this.child.exitCode === null && this.child.signalCode === null)) {
      throw new Error('The engine did not stop; the data folder stays owned.')
    }
    this.lease.release(); this.lease = null
  }

  // ── One boot ──────────────────────────────────────────────────────────────

  private async choosePorts(): Promise<void> {
    this.pgPort = await freePort()
    if (this.options.port !== null) {
      this.port = await freePort(this.options.port)
      return
    }
    const last = Number.parseInt(fs.existsSync(path.join(this.dataDir, 'port')) ? fs.readFileSync(path.join(this.dataDir, 'port'), 'utf8') : '', 10)
    this.port = Number.isInteger(last) && last >= 1024 && last !== this.pgPort ? await freePort(last).catch(() => freePort()) : await freePort()
    if (this.port === this.pgPort) this.port = await freePort()
  }

  private assertDatabaseMajor(): void {
    const file = path.join(this.pgData, 'PG_VERSION')
    if (!fs.existsSync(file)) return
    const have = fs.readFileSync(file, 'utf8').trim().split('.')[0]
    const carried = this.release.manifest.postgres?.version.split('.')[0]
    if (carried && have !== carried) {
      throw new Error(`This data folder's database was made by PostgreSQL ${have}; this engine carries PostgreSQL ${carried}. Nothing was changed.`)
    }
  }

  private async initCluster(signal: AbortSignal): Promise<void> {
    const passwordFile = path.join(this.dataDir, 'tmp', 'init-password')
    fs.writeFileSync(passwordFile, this.secrets!.pgPassword, { mode: 0o600 })
    const staging = this.pgData + '.init'
    fs.rmSync(staging, { recursive: true, force: true })
    try {
      const locale = this.localeEnv().LC_ALL!
      await this.pg('initdb', ['-D', staging, '-U', 'postgres', '--auth=scram-sha-256', '--pwfile=' + passwordFile, '-E', 'UTF8', '--locale=' + locale], 120_000, signal)
    } finally {
      fs.rmSync(passwordFile, { force: true })
    }
    // TCP on loopback only, no Unix socket: nothing outside this machine, and nothing
    // that shares /tmp, can reach the cluster. The port is passed on every start.
    fs.appendFileSync(path.join(staging, 'postgresql.conf'), "\n# @barkpark/engine\nlisten_addresses = '127.0.0.1'\nunix_socket_directories = ''\n")
    fs.renameSync(staging, this.pgData)
  }

  private releaseEnv(): NodeJS.ProcessEnv {
    const s = this.secrets!
    return {
      PATH: SYSTEM_PATH, HOME: path.join(this.dataDir, 'home'), ...this.localeEnv(), ...releaseKeys(s.pgPassword),
      DATABASE_URL: `ecto://postgres:${encodeURIComponent(s.pgPassword)}@127.0.0.1:${this.pgPort}/${DATABASE}`, POOL_SIZE: '5',
      // The listen port and the public port are separate settings. Without PHX_PORT a
      // release assumes the scheme's standard port in every absolute URL it hands out,
      // so media URLs came back as http://127.0.0.1/media/... and could not be fetched.
      PORT: String(this.port), PHX_PORT: String(this.port), PHX_HOST: '127.0.0.1', PHX_SCHEME: 'http',
      RELEASE_DISTRIBUTION: 'none', RELEASE_TMP: path.join(this.dataDir, 'tmp'), ERL_CRASH_DUMP: path.join(this.logDir, 'erl_crash.dump'),
      BARKPARK_SHAPE: 'app', BARKPARK_HTTP_IP: '127.0.0.1', BARKPARK_TMUX_CONSOLE: '0', BARKPARK_CLAUDE_CHAT: '0',
      ...(this.options.plugins ? { BARKPARK_PLUGINS: this.options.plugins.join(',') } : {}),
      BARKPARK_MEDIA_DIR: path.join(this.dataDir, 'media'), BARKPARK_INDX_STATE_DIR: path.join(this.dataDir, 'indx'),
      BARKPARK_BUNDLE_SPILL_DIR: path.join(this.dataDir, 'bundles'),
    }
  }

  private async evaluate(expression: string, env: NodeJS.ProcessEnv, timeout: number, signal: AbortSignal): Promise<void> {
    try {
      const { stdout, stderr } = await run(this.release.bin, ['eval', expression], { env, timeout, signal })
      this.log('server.log', stdout); this.log('server.log', stderr)
    } catch (error) {
      const e = error as Error & { stdout?: string; stderr?: string }
      this.log('server.log', e.stdout ?? ''); this.log('server.log', e.stderr ?? '')
      throw new Error(`${expression} failed: ${this.redact(String(e.stderr || e.stdout || e.message)).slice(-800)}`)
    }
  }

  private async bootOnce(signal: AbortSignal): Promise<void> {
    await this.record.reclaim({ running: () => this.pgRunning(), stop: () => this.stopPg() })
    signal.throwIfAborted()
    await this.choosePorts()
    this.assertDatabaseMajor()
    if (!fs.existsSync(path.join(this.pgData, 'PG_VERSION'))) await this.initCluster(signal)
    if (await this.pgRunning()) throw new Error('The private database is already running without this engine. It was left untouched.')
    signal.throwIfAborted()
    this.pgOwned = true
    this.record.write({ port: this.port, pgPort: this.pgPort })
    await this.pg('pg_ctl', ['-D', this.pgData, '-l', path.join(this.logDir, 'postgres.log'), '-o', `-p ${this.pgPort}`, '-w', '-t', '60', 'start'], 90_000, signal)
    const { stdout } = await this.pg('psql', [...this.at(), '-d', 'postgres', '-tAc', `SELECT 1 FROM pg_database WHERE datname = '${DATABASE}'`], 15_000, signal)
    if (stdout.trim() !== '1') await this.pg('createdb', [...this.at(), DATABASE], 60_000, signal)
    const env = this.releaseEnv()
    await this.evaluate('Barkpark.Release.migrate()', env, 15 * 60_000, signal)
    const seeded = path.join(this.dataDir, 'seeded')
    if (!fs.existsSync(seeded)) {
      // The release's own seed entry boots the tree without the listener and with the
      // job queue inert. The token reaches the seed through its environment only.
      await this.evaluate('Barkpark.Release.seed()', { ...env, BARKPARK_SEED_PROFILE: 'clean', BARKPARK_SEED_ADMIN_TOKEN: this.secrets!.adminToken }, 5 * 60_000, signal)
      fs.writeFileSync(seeded, 'clean\n')
    }
    signal.throwIfAborted()
    fs.writeFileSync(path.join(this.dataDir, 'port'), String(this.port))
    this.childError = null
    const child = spawn(this.release.bin, ['start'], { env: { ...env, PHX_SERVER: 'true' }, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    this.child = child
    child.stdout?.on('data', (chunk: Buffer) => this.log('server.log', chunk.toString()))
    child.stderr?.on('data', (chunk: Buffer) => this.log('server.log', chunk.toString()))
    child.on('error', error => { this.childError = error.message })
    if (child.pid) this.record.write({ pid: child.pid, port: this.port, pgPort: this.pgPort })
  }

  private childFailed(): string | null {
    if (this.childError) return this.childError
    if (!this.child || this.child.exitCode !== null || this.child.signalCode !== null) return `The Barkpark server exited. See ${path.join(this.logDir, 'server.log')}.`
    return null
  }

  async healthy(signal: AbortSignal): Promise<boolean> {
    if (this.childFailed()) return false
    try {
      const response = await fetch(`${this.url}/status.json`, { signal: AbortSignal.any([signal, AbortSignal.timeout(5_000)]) })
      if (!response.ok) return false
      const body = await response.json() as { components?: { name?: string; status?: string }[] }
      return ['database', 'migrations', 'plugins'].every(name => body.components?.some(c => c.name === name && c.status === 'operational'))
    } catch {
      return false
    }
  }

  async stopAll(): Promise<void> {
    const child = this.child
    if (child && child.pid && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise<void>(resolve => child.once('exit', () => resolve()))
      const alive = () => child.exitCode === null && child.signalCode === null
      await stopProcessGroup(child.pid, alive)
      if (alive()) throw new Error('The Barkpark server did not stop; the data folder stays owned.')
      await exited
    }
    this.child = null
    if (this.pgOwned) {
      await this.stopPg()
      this.pgOwned = false
    }
    this.record.clear()
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  async start(): Promise<void> {
    this.abort = new AbortController()
    this.state = { phase: 'starting', attempts: 0, error: null }
    const op = this.boot(this.abort.signal)
    this.operation = op
    try { await op } finally { this.operation = null }
  }

  private async boot(signal: AbortSignal): Promise<void> {
    for (;;) {
      signal.throwIfAborted()
      this.update(this.state.attempts ? 'recovering' : 'starting', this.state.error)
      try {
        await this.bootOnce(signal)
        const deadline = Date.now() + this.options.startupTimeoutMs
        for (;;) {
          if (await this.healthy(signal)) { this.missed = 0; this.update('ready'); this.schedule(); return }
          const failed = this.childFailed()
          if (failed) throw new Error(failed)
          if (Date.now() > deadline) throw new Error(`Barkpark did not answer /status.json within ${this.options.startupTimeoutMs} ms. See ${this.logDir}.`)
          await sleep(500, signal)
        }
      } catch (error) {
        await this.stopAll().catch(stopError => { this.log('engine.log', `stop after failed boot: ${String(stopError)}\n`) })
        signal.throwIfAborted()
        this.log('engine.log', `${new Date().toISOString()} boot failed: ${(error as Error).message}\n`)
        if (++this.state.attempts > this.options.retries) { this.update('failed', (error as Error).message); throw error }
        this.update('recovering', (error as Error).message)
        await sleep(Math.min(1_000 * this.state.attempts, 10_000), signal)
      }
    }
  }

  private schedule(soon = false): void {
    if (this.timer) clearTimeout(this.timer)
    this.timer = setTimeout(() => { void this.monitor() }, soon ? Math.min(this.options.healthIntervalMs, 1_000) : this.options.healthIntervalMs)
    this.timer.unref()
  }

  private async monitor(): Promise<void> {
    const signal = this.abort?.signal
    if (!signal || signal.aborted || this.operation) return
    const op = (async () => {
      try {
        if (await this.healthy(signal)) { this.missed = 0; this.schedule(); return }
        signal.throwIfAborted()
        // One slow answer under load is not a stopped server: restart after three misses in a row.
        if (++this.missed < 3) { this.schedule(true); return }
        this.missed = 0
        this.log('engine.log', `${new Date().toISOString()} server stopped answering; restarting\n`)
        await this.stopAll()
        if (++this.state.attempts > this.options.retries) throw new Error('Barkpark stopped answering and the restart budget is used up.')
        await this.boot(signal)
      } catch (error) {
        if (!signal.aborted) this.update('failed', (error as Error).message)
      }
    })()
    this.operation = op
    try { await op } finally { this.operation = null }
  }

  async stop(): Promise<void> {
    if (this.timer) clearTimeout(this.timer)
    this.abort?.abort(new Error('The engine is stopping.'))
    await this.operation?.catch(() => {})
    this.update('stopping')
    try {
      await this.stopAll()
      this.releaseOwnership()
      this.update('stopped')
    } catch (error) {
      this.update('failed', (error as Error).message)
      throw error
    }
  }
}

/**
 * Start Barkpark for one dataDir and resolve once it answers. Rejects when the
 * dataDir is owned by another live process, when the release is missing or built
 * for another platform, or when boot fails more than `retries` times.
 */
export async function startBarkpark(options: StartBarkparkOptions): Promise<Barkpark> {
  const engine = new Engine(normalizeOptions(options))
  engine.acquire()
  try {
    await engine.start()
  } catch (error) {
    await engine.stopAll().catch(() => {})
    try { engine.releaseOwnership() } catch { /* the folder stays owned; the error below says why the start failed */ }
    throw error
  }
  let stopped: Promise<void> | null = null
  return Object.freeze({
    url: engine.url,
    token: engine.token,
    port: engine.port,
    dataDir: engine.dataDir,
    commit: engine.release.manifest.commit,
    status: () => engine.status(),
    stop: () => (stopped ??= engine.stop()),
  })
}
