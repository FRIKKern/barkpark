import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderTemplate } from '../src/scaffold'

/**
 * Shipped bug: website-starter and blog-starter both pinned
 * `"@barkpark/react": "^1.0.0-preview.2"` while @barkpark/react had only ever
 * published through preview.1 — a caret range on a prerelease line does NOT
 * float up to a later prerelease, so `npm install` in a freshly scaffolded
 * project failed at resolution, before a new user wrote a single line of
 * code. This test is OFFLINE and deterministic: it never calls npm. It reads
 * the workspace's own package.json files as the source of truth for "what is
 * safe to depend on" and checks every `@barkpark/*` pin in every starter
 * template's package.json.tmpl against it, catching this defect's whole
 * shape rather than just this one instance.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES_DIR = path.resolve(HERE, '..', 'templates')
const PACKAGES_DIR = path.resolve(HERE, '..', '..')

/** Strip a semver range operator (^, ~, >=, >, <=, <, =) to get the pin floor. */
function floorVersion(pin: string): string {
  return pin.trim().replace(/^(\^|~|>=|>|<=|<|=)\s*/, '')
}

function parseSemver(version: string): { nums: number[]; prerelease: string[] } {
  // `String.prototype.split` always yields at least one element, but
  // `noUncheckedIndexedAccess` cannot know that: `core` is typed
  // `string | undefined`. The `= ''` default is a real guard, not a silencer —
  // an empty core parses to [0, 0, 0] below, the same answer the old code
  // would have produced for `parseSemver('')`.
  const [core = '', ...preParts] = version.split('-')
  const prerelease = preParts.length ? preParts.join('-').split('.') : []
  const nums = core.split('.').map((n) => Number.parseInt(n, 10) || 0)
  while (nums.length < 3) nums.push(0)
  return { nums, prerelease }
}

function compareIdentifier(a: string, b: string): number {
  const aNumeric = /^\d+$/.test(a)
  const bNumeric = /^\d+$/.test(b)
  if (aNumeric && bNumeric) return Number(a) - Number(b)
  if (aNumeric && !bNumeric) return -1
  if (!aNumeric && bNumeric) return 1
  return a < b ? -1 : a > b ? 1 : 0
}

/** Semver precedence compare: <0 if a<b, 0 if equal, >0 if a>b. A release (no prerelease) outranks any prerelease of the same core version. */
function compareVersions(a: string, b: string): number {
  const pa = parseSemver(a)
  const pb = parseSemver(b)
  for (let i = 0; i < 3; i++) {
    // parseSemver pads `nums` to length 3, so `?? 0` never fires at runtime;
    // it is the narrowing tsc needs, and it agrees with that padding.
    const na = pa.nums[i] ?? 0
    const nb = pb.nums[i] ?? 0
    if (na !== nb) return na - nb
  }
  if (pa.prerelease.length === 0 && pb.prerelease.length === 0) return 0
  if (pa.prerelease.length === 0) return 1
  if (pb.prerelease.length === 0) return -1
  const len = Math.max(pa.prerelease.length, pb.prerelease.length)
  for (let i = 0; i < len; i++) {
    // Bind once so the `undefined` checks actually NARROW the value handed to
    // compareIdentifier. Re-indexing (as before) re-widens it to
    // `string | undefined` on every read.
    const ia = pa.prerelease[i]
    const ib = pb.prerelease[i]
    if (ia === undefined) return -1
    if (ib === undefined) return 1
    const c = compareIdentifier(ia, ib)
    if (c !== 0) return c
  }
  return 0
}

/** Dummy substitution vars: enough for package.json.tmpl's {{placeholders}} to survive JSON.parse. */
const TEMPLATE_VARS: Record<string, string> = {
  projectName: 'template-pins-fixture',
  packageName: 'template-pins-fixture',
  pmCommand: 'pnpm',
  barkparkVersion: '0.0.0',
}

async function listTemplateDirs(): Promise<string[]> {
  const entries = await fs.readdir(TEMPLATES_DIR, { withFileTypes: true })
  return entries.filter((e) => e.isDirectory()).map((e) => e.name)
}

async function readWorkspacePackageVersion(pkgName: string): Promise<string | undefined> {
  // '@barkpark/react' -> packages/react
  const dirName = pkgName.replace(/^@barkpark\//, '')
  const pkgJsonPath = path.join(PACKAGES_DIR, dirName, 'package.json')
  try {
    const raw = await fs.readFile(pkgJsonPath, 'utf8')
    return (JSON.parse(raw) as { version?: string }).version
  } catch {
    return undefined
  }
}

/**
 * Ordering arm for the hand-rolled comparator above. The four
 * `noUncheckedIndexedAccess` faults in `parseSemver`/`compareVersions` are
 * fixable in ways that satisfy tsc while QUIETLY changing precedence (an
 * `?? 0` in the wrong loop, dropping an `undefined` check, an `any` cast that
 * lets a typo through). Those cases stay invisible to the pin check below,
 * which only ever compares a template pin against a workspace version. These
 * assertions pin the semver-precedence contract itself, so a future edit to
 * the comparator has to keep answering the same way.
 */
describe('compareVersions (semver precedence)', () => {
  const sgn = (n: number) => (n < 0 ? -1 : n > 0 ? 1 : 0)

  it('orders by major, then minor, then patch', () => {
    expect(sgn(compareVersions('1.0.0', '2.0.0'))).toBe(-1)
    expect(sgn(compareVersions('2.0.0', '1.9.9'))).toBe(1)
    expect(sgn(compareVersions('1.2.0', '1.10.0'))).toBe(-1)
    expect(sgn(compareVersions('1.2.3', '1.2.4'))).toBe(-1)
    expect(sgn(compareVersions('1.2.3', '1.2.3'))).toBe(0)
  })

  it('pads missing components with zero', () => {
    expect(sgn(compareVersions('1', '1.0.0'))).toBe(0)
    expect(sgn(compareVersions('1.2', '1.2.0'))).toBe(0)
    expect(sgn(compareVersions('1.2', '1.2.1'))).toBe(-1)
  })

  it('ranks a release above any prerelease of the same core', () => {
    expect(sgn(compareVersions('1.0.0', '1.0.0-preview.1'))).toBe(1)
    expect(sgn(compareVersions('1.0.0-preview.1', '1.0.0'))).toBe(-1)
    expect(sgn(compareVersions('1.0.1-preview.1', '1.0.0'))).toBe(1)
  })

  it('compares prerelease identifiers left to right, numerically when both are numeric', () => {
    expect(sgn(compareVersions('1.0.0-preview.1', '1.0.0-preview.2'))).toBe(-1)
    expect(sgn(compareVersions('1.0.0-preview.2', '1.0.0-preview.10'))).toBe(-1)
    expect(sgn(compareVersions('1.0.0-alpha.1', '1.0.0-beta.1'))).toBe(-1)
    expect(sgn(compareVersions('1.0.0-preview.1', '1.0.0-preview.1'))).toBe(0)
  })

  it('ranks a numeric identifier below an alphanumeric one, and a shorter prerelease below its own prefix-extension', () => {
    expect(sgn(compareVersions('1.0.0-1', '1.0.0-alpha'))).toBe(-1)
    expect(sgn(compareVersions('1.0.0-alpha', '1.0.0-alpha.1'))).toBe(-1)
    expect(sgn(compareVersions('1.0.0-alpha.1', '1.0.0-alpha'))).toBe(1)
  })

  it('is the ordering the pin check relies on: a preview.2 floor is above a preview.1 workspace version', () => {
    // The shipped bug this file was written for.
    expect(compareVersions(floorVersion('^1.0.0-preview.2'), '1.0.0-preview.1')).toBeGreaterThan(0)
    expect(compareVersions(floorVersion('^1.0.0-preview.1'), '1.0.0-preview.1')).toBe(0)
  })
})

describe('starter template @barkpark/* pins', () => {
  it('finds at least one template with a package.json.tmpl', async () => {
    const dirs = await listTemplateDirs()
    expect(dirs.length).toBeGreaterThan(0)
  })

  it('pins every @barkpark/* dependency at or below the version declared in the workspace package', async () => {
    const templateDirs = await listTemplateDirs()
    expect(templateDirs.length).toBeGreaterThan(0)

    const offenders: string[] = []

    for (const templateDir of templateDirs) {
      const tmplPath = path.join(TEMPLATES_DIR, templateDir, 'package.json.tmpl')
      let raw: string
      try {
        raw = await fs.readFile(tmplPath, 'utf8')
      } catch {
        continue // this starter has no package.json.tmpl — nothing to check
      }

      const rendered = renderTemplate(raw, TEMPLATE_VARS)
      const parsed = JSON.parse(rendered) as {
        dependencies?: Record<string, string>
        devDependencies?: Record<string, string>
      }

      const allDeps = { ...parsed.dependencies, ...parsed.devDependencies }

      for (const [depName, pin] of Object.entries(allDeps)) {
        if (!depName.startsWith('@barkpark/')) continue

        const declared = await readWorkspacePackageVersion(depName)
        if (declared === undefined) {
          offenders.push(
            `${templateDir}/package.json.tmpl pins "${depName}": "${pin}" but no workspace package.json was found for ${depName}`,
          )
          continue
        }

        const floor = floorVersion(pin)
        if (compareVersions(floor, declared) > 0) {
          offenders.push(
            `${templateDir}/package.json.tmpl pins "${depName}": "${pin}" (floor ${floor}) above the workspace's declared ${declared} — npm install would fail to resolve it`,
          )
        }
      }
    }

    expect(offenders).toEqual([])
  })
})
