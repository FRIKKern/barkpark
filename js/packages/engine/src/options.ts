import path from 'node:path'

/** What `startBarkpark` accepts. */
export interface StartBarkparkOptions {
  /** Folder the engine owns: database, media, search state, logs and secrets. Created if missing. */
  dataDir: string
  /**
   * Plugins to enable, passed to the server as BARKPARK_PLUGINS. Leave it out to
   * enable every plugin the release carries. An empty list enables none.
   */
  plugins?: readonly string[]
  /** HTTP port on 127.0.0.1. Defaults to the port this dataDir used last, else a free one. */
  port?: number
  /**
   * Engine folder built by scripts/engine/build-release.mjs. Defaults to the
   * BARKPARK_ENGINE_RELEASE environment variable, then to the engine folder in the
   * installed @barkpark/engine-<platform>-<arch> package.
   */
  release?: string
  /** How long one boot may take before it counts as failed. Default 180 s. */
  startupTimeoutMs?: number
  /** Restarts allowed after a failed boot or a stopped server, per start. Default 3. */
  retries?: number
  /** Interval between health checks once ready. Default 5 s. */
  healthIntervalMs?: number
}

export interface EngineOptions {
  dataDir: string
  plugins: readonly string[] | null
  port: number | null
  release: string | null
  startupTimeoutMs: number
  retries: number
  healthIntervalMs: number
}

export class EngineOptionsError extends TypeError {
  readonly code = 'engine_options'
}

const PLUGIN_NAME = /^[a-z][a-z0-9_]*$/

function positiveInteger(name: string, value: unknown, fallback: number, min: number, max: number): number {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) {
    throw new EngineOptionsError(`${name} must be an integer from ${min} to ${max}.`)
  }
  return value
}

/** Check and fill in the options. Throws EngineOptionsError naming the bad field. */
export function normalizeOptions(options: StartBarkparkOptions, env: NodeJS.ProcessEnv = process.env): EngineOptions {
  if (options === null || typeof options !== 'object') throw new EngineOptionsError('startBarkpark needs an options object with a dataDir.')
  const { dataDir, plugins, port, release } = options
  if (typeof dataDir !== 'string' || dataDir.trim() === '') throw new EngineOptionsError('dataDir must be a folder path.')
  let pluginList: readonly string[] | null = null
  if (plugins !== undefined) {
    if (!Array.isArray(plugins)) throw new EngineOptionsError('plugins must be an array of plugin names.')
    for (const name of plugins) {
      if (typeof name !== 'string' || !PLUGIN_NAME.test(name)) {
        throw new EngineOptionsError(`plugins contains ${JSON.stringify(name)}; a plugin name is lower case letters, digits and underscores.`)
      }
    }
    pluginList = Object.freeze([...new Set(plugins as string[])])
  }
  const releaseValue = release ?? (env.BARKPARK_ENGINE_RELEASE || undefined)
  if (releaseValue !== undefined && (typeof releaseValue !== 'string' || releaseValue.trim() === '')) {
    throw new EngineOptionsError('release must be the path of an engine folder.')
  }
  return {
    dataDir: path.resolve(dataDir),
    plugins: pluginList,
    port: port === undefined ? null : positiveInteger('port', port, 0, 1024, 65535),
    release: releaseValue === undefined ? null : path.resolve(releaseValue),
    startupTimeoutMs: positiveInteger('startupTimeoutMs', options.startupTimeoutMs, 180_000, 1_000, 3_600_000),
    retries: positiveInteger('retries', options.retries, 3, 0, 10),
    healthIntervalMs: positiveInteger('healthIntervalMs', options.healthIntervalMs, 5_000, 100, 600_000),
  }
}
