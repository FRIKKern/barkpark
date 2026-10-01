// `create-barkpark-app --version` printed 1.0.0-preview.0 while the package was
// 1.0.0-preview.1: the build injected a hard-coded literal no release ever
// bumped (stranger walk, 2026-10-01). The build now reads package.json; this
// pins the BUILT CLI (js-tests.yml builds before it tests) to it.
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

const PKG_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const pkg = JSON.parse(readFileSync(path.join(PKG_DIR, 'package.json'), 'utf8')) as {
  version: string
}
const DIST = path.join(PKG_DIR, 'dist', 'index.js')

describe('--version', () => {
  it.skipIf(!existsSync(DIST))('prints the version in package.json', () => {
    const out = execFileSync(process.execPath, [DIST, '--version'], { encoding: 'utf8' }).trim()
    expect(out).toBe(pkg.version)
  })

  it('the build config takes the version from package.json, not a literal', () => {
    const cfg = readFileSync(path.join(PKG_DIR, 'tsup.config.ts'), 'utf8')
    expect(cfg).toMatch(/readFileSync\(new URL\('\.\/package\.json'/)
    expect(cfg).not.toMatch(/BARKPARK_VERSION\s*=\s*'\d/)
  })
})
