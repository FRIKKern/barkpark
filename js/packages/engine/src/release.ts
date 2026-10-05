// Find and check the engine folder to run. Today the caller names it (the `release`
// option or BARKPARK_ENGINE_RELEASE). This is the one place that changes when the
// folder comes from a platform package (@barkpark/engine-<platform>-<arch>) or from
// `bp build`: resolveRelease gains those sources and returns the same shape.
import fs from 'node:fs'
import path from 'node:path'

export const MANIFEST = 'engine.json'
/** The Postgres programs the engine runs; the build keeps exactly these. */
export const PROGRAMS = ['initdb', 'pg_ctl', 'postgres', 'psql', 'createdb'] as const

export interface EngineManifest {
  version: 1
  commit: string
  builtAt: string
  platform: string
  arch: string
  erts: string
  otp: string
  elixir: string
  postgres: { version: string; extensions: string[]; programs: string[] } | null
}

export interface ResolvedRelease {
  root: string
  bin: string
  pgBin: string
  manifest: EngineManifest
}

export class EngineReleaseError extends Error {
  readonly code = 'engine_release'
}

export function resolveRelease(release: string | null, host: { platform: string; arch: string } = process): ResolvedRelease {
  if (release === null) {
    throw new EngineReleaseError('No engine release was given. Pass `release` (a folder built by scripts/engine/build-release.mjs) or set BARKPARK_ENGINE_RELEASE.')
  }
  if (host.platform !== 'darwin' && host.platform !== 'linux') throw new EngineReleaseError(`The engine runs on macOS and Linux for now, not ${host.platform}.`)
  const bin = path.join(release, 'bin', 'barkpark')
  if (!fs.existsSync(bin) || !fs.existsSync(path.join(release, 'releases'))) {
    throw new EngineReleaseError(`${release} is not an engine folder: bin/barkpark or releases/ is missing.`)
  }
  let manifest: EngineManifest
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(release, MANIFEST), 'utf8')) as EngineManifest
  } catch {
    throw new EngineReleaseError(`${release} has no readable ${MANIFEST}; build it with scripts/engine/build-release.mjs.`)
  }
  if (manifest.version !== 1 || !/^[0-9a-f]{40}$/.test(manifest.commit)) throw new EngineReleaseError(`${path.join(release, MANIFEST)} is not a version 1 engine manifest.`)
  if (manifest.platform !== host.platform || manifest.arch !== host.arch) {
    throw new EngineReleaseError(`This engine folder was built for ${manifest.platform}-${manifest.arch}; this machine is ${host.platform}-${host.arch}.`)
  }
  if (!manifest.postgres) throw new EngineReleaseError(`${release} carries no Postgres. Add one with scripts/engine/build-release.mjs --add-postgres.`)
  const pgBin = path.join(release, 'postgres', 'bin')
  const missing = PROGRAMS.filter(name => !fs.existsSync(path.join(pgBin, name)))
  if (missing.length) throw new EngineReleaseError(`${pgBin} is missing ${missing.join(', ')}.`)
  return { root: release, bin, pgBin, manifest }
}
