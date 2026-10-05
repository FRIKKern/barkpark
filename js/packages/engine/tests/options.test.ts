import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { normalizeOptions, EngineOptionsError } from '../src/options'
import { resolveRelease, findPlatformRelease, platformPackage, EngineReleaseError, PROGRAMS } from '../src/release'
import { loadOrCreateSecrets, redactor, releaseKeys } from '../src/secrets'

describe('normalizeOptions', () => {
  it('fills in defaults and resolves the dataDir', () => {
    const o = normalizeOptions({ dataDir: 'rel/dir' }, {})
    expect(o.dataDir).toBe(path.resolve('rel/dir'))
    expect(o).toMatchObject({ plugins: null, port: null, release: null, startupTimeoutMs: 180_000, retries: 3, healthIntervalMs: 5_000 })
  })

  it('keeps an empty plugin list, which turns every plugin off', () => {
    expect(normalizeOptions({ dataDir: '/d', plugins: [] }, {}).plugins).toEqual([])
  })

  it('removes repeated plugin names and keeps their order', () => {
    expect(normalizeOptions({ dataDir: '/d', plugins: ['bulldocs', 'media', 'bulldocs'] }, {}).plugins).toEqual(['bulldocs', 'media'])
  })

  it.each([
    [{ dataDir: '' }, /dataDir/],
    [{ dataDir: '/d', plugins: 'bulldocs' }, /plugins must be an array/],
    [{ dataDir: '/d', plugins: ['Bulldocs'] }, /plugin name/],
    [{ dataDir: '/d', plugins: ['a,b'] }, /plugin name/],
    [{ dataDir: '/d', port: 80 }, /port/],
    [{ dataDir: '/d', port: 4000.5 }, /port/],
    [{ dataDir: '/d', retries: -1 }, /retries/],
    [{ dataDir: '/d', release: '' }, /release/],
  ])('refuses %j', (input, message) => {
    expect(() => normalizeOptions(input as never, {})).toThrow(EngineOptionsError)
    expect(() => normalizeOptions(input as never, {})).toThrow(message)
  })

  it('takes the release from BARKPARK_ENGINE_RELEASE when the option is absent', () => {
    expect(normalizeOptions({ dataDir: '/d' }, { BARKPARK_ENGINE_RELEASE: '/opt/engine' }).release).toBe('/opt/engine')
    expect(normalizeOptions({ dataDir: '/d', release: '/x' }, { BARKPARK_ENGINE_RELEASE: '/opt/engine' }).release).toBe('/x')
  })
})

describe('resolveRelease', () => {
  const fakeRelease = (manifest: Record<string, unknown>, programs: readonly string[] = PROGRAMS) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'engine-release-'))
    fs.mkdirSync(path.join(root, 'bin'))
    fs.mkdirSync(path.join(root, 'releases'))
    fs.writeFileSync(path.join(root, 'bin', 'barkpark'), '')
    fs.mkdirSync(path.join(root, 'postgres', 'bin'), { recursive: true })
    for (const name of programs) fs.writeFileSync(path.join(root, 'postgres', 'bin', name), '')
    fs.writeFileSync(path.join(root, 'engine.json'), JSON.stringify(manifest))
    return root
  }
  const good = { version: 1, commit: 'a'.repeat(40), platform: 'linux', arch: 'x64', postgres: { version: '15.18', extensions: [], programs: [...PROGRAMS] } }

  const notInstalled = () => { throw Object.assign(new Error('Cannot find module'), { code: 'MODULE_NOT_FOUND' }) }
  // A node_modules/<platform package>/ holding an engine folder, and a resolver that finds it.
  const installed = (manifest: Record<string, unknown>) => {
    const pkg = fs.mkdtempSync(path.join(os.tmpdir(), 'engine-platform-package-'))
    fs.renameSync(fakeRelease(manifest), path.join(pkg, 'engine'))
    fs.writeFileSync(path.join(pkg, 'package.json'), '{}')
    const asked: string[] = []
    const resolve = (specifier: string) => { asked.push(specifier); return path.join(pkg, 'package.json') }
    return { pkg, resolve, asked }
  }

  it('says where a release comes from when none is given and no platform package is installed', () => {
    const host = { platform: 'linux', arch: 'x64' }
    expect(() => resolveRelease(null, host, notInstalled)).toThrow(/@barkpark\/engine-linux-x64 is not installed/)
    expect(() => resolveRelease(null, host, notInstalled)).toThrow(/BARKPARK_ENGINE_RELEASE/)
    expect(() => resolveRelease(null, { platform: 'linux', arch: 'ia32' }, notInstalled)).toThrow(/no platform package for linux-ia32/)
  })

  it('names the platform package after the machine', () => {
    expect(platformPackage({ platform: 'darwin', arch: 'arm64' })).toBe('@barkpark/engine-darwin-arm64')
    expect(findPlatformRelease({ platform: 'linux', arch: 'x64' }, notInstalled)).toBeNull()
  })

  it('takes the engine folder from the installed platform package when no release is given', () => {
    const { pkg, resolve, asked } = installed(good)
    const resolved = resolveRelease(null, { platform: 'linux', arch: 'x64' }, resolve)
    expect(asked).toEqual(['@barkpark/engine-linux-x64/package.json'])
    expect(resolved.root).toBe(path.join(pkg, 'engine'))
    expect(resolved.bin).toBe(path.join(pkg, 'engine', 'bin', 'barkpark'))
  })

  it('prefers a named release over the platform package', () => {
    const { resolve, asked } = installed(good)
    const named = fakeRelease(good)
    expect(resolveRelease(named, { platform: 'linux', arch: 'x64' }, resolve).root).toBe(named)
    expect(asked).toEqual([])
  })

  it('checks a platform package folder like any other', () => {
    const { resolve } = installed({ ...good, postgres: null })
    expect(() => resolveRelease(null, { platform: 'linux', arch: 'x64' }, resolve)).toThrow(/--add-postgres/)
  })

  it('resolves the real platform package specifier through node resolution', () => {
    // Nothing named @barkpark/engine-* is installed in this workspace, so the
    // default resolver must answer null, not throw.
    expect(findPlatformRelease({ platform: 'linux', arch: 'x64' })).toBeNull()
  })

  it('accepts a complete engine folder for this platform', () => {
    const root = fakeRelease(good)
    expect(resolveRelease(root, { platform: 'linux', arch: 'x64' })).toMatchObject({ root, bin: path.join(root, 'bin', 'barkpark') })
  })

  it('refuses a folder built for another platform', () => {
    expect(() => resolveRelease(fakeRelease(good), { platform: 'darwin', arch: 'arm64' })).toThrow(/built for linux-x64/)
  })

  it('refuses a folder without Postgres or with programs missing', () => {
    expect(() => resolveRelease(fakeRelease({ ...good, postgres: null }), { platform: 'linux', arch: 'x64' })).toThrow(/--add-postgres/)
    expect(() => resolveRelease(fakeRelease(good, ['initdb']), { platform: 'linux', arch: 'x64' })).toThrow(EngineReleaseError)
  })

  it('refuses a folder that is not an engine folder', () => {
    expect(() => resolveRelease(fs.mkdtempSync(path.join(os.tmpdir(), 'engine-empty-')), { platform: 'linux', arch: 'x64' })).toThrow(/not an engine folder/)
  })
})

describe('secrets', () => {
  it('creates secrets once, owner-readable only, and returns the same ones later', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'engine-secrets-'))
    const first = loadOrCreateSecrets(dir)
    expect(first.created).toBe(true)
    expect(first.adminToken).toMatch(/^bp_admin_[A-Za-z0-9_-]{32}$/)
    expect(fs.statSync(path.join(dir, 'secrets.json')).mode & 0o077).toBe(0)
    const second = loadOrCreateSecrets(dir)
    expect(second).toEqual({ ...first, created: false })
  })

  it('derives the same release keys from the same password, and keys long enough for a prod boot', () => {
    const keys = releaseKeys('p'.repeat(43))
    expect(releaseKeys('p'.repeat(43))).toEqual(keys)
    expect(keys.SECRET_KEY_BASE!.length).toBeGreaterThanOrEqual(64)
    expect(Buffer.from(keys.BARKPARK_KEK!, 'base64')).toHaveLength(32)
  })

  it('redacts every secret from text', () => {
    const redact = redactor(['secret-token-1234', 'pw-abcdefgh'])
    expect(redact('a secret-token-1234 b pw-abcdefgh secret-token-1234')).toBe('a [redacted] b [redacted] [redacted]')
  })
})
