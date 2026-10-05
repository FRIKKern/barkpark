// Find and check the engine folder to run. The caller can name it (the `release`
// option or BARKPARK_ENGINE_RELEASE). Otherwise it comes from the platform package
// npm installed beside @barkpark/engine (@barkpark/engine-<platform>-<arch>, listed
// as an optional dependency, so npm fetches only the one matching this machine).
// `bp build` for a custom Barkpark will be one more source returning the same shape.
import fs from 'node:fs'
import { createRequire } from 'node:module'
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

type Host = { platform: string; arch: string }

/** The platforms that have a platform package. */
export const PLATFORMS = ['darwin-arm64', 'linux-x64', 'linux-arm64'] as const

/** The npm package that carries the engine folder for one platform. */
export function platformPackage(host: Host): string {
  return `@barkpark/engine-${host.platform}-${host.arch}`
}

/** Resolves a module specifier the way this package's own require would. */
export type Resolve = (specifier: string) => string

const resolveFromHere: Resolve = specifier => createRequire(import.meta.url).resolve(specifier)

/** The engine folder inside the installed platform package, or null when none is installed. */
export function findPlatformRelease(host: Host = process, resolve: Resolve = resolveFromHere): string | null {
  let manifest: string
  try {
    manifest = resolve(`${platformPackage(host)}/package.json`)
  } catch {
    return null
  }
  return path.join(path.dirname(manifest), 'engine')
}

export function resolveRelease(given: string | null, host: Host = process, resolve: Resolve = resolveFromHere): ResolvedRelease {
  if (host.platform !== 'darwin' && host.platform !== 'linux') throw new EngineReleaseError(`The engine runs on macOS and Linux for now, not ${host.platform}.`)
  const release = given ?? findPlatformRelease(host, resolve)
  if (release === null) {
    const name = platformPackage(host)
    const known = (PLATFORMS as readonly string[]).includes(`${host.platform}-${host.arch}`)
    throw new EngineReleaseError(
      known
        ? `No engine folder was found. ${name} is not installed: npm installs it with @barkpark/engine unless optional dependencies are turned off. Or pass \`release\` (a folder built by scripts/engine/build-release.mjs) or set BARKPARK_ENGINE_RELEASE.`
        : `No engine folder was found, and there is no platform package for ${host.platform}-${host.arch}. Pass \`release\` (a folder built by scripts/engine/build-release.mjs) or set BARKPARK_ENGINE_RELEASE.`,
    )
  }
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
