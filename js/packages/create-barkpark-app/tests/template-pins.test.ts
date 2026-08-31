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
  const [core, ...preParts] = version.split('-')
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
    if (pa.nums[i] !== pb.nums[i]) return pa.nums[i] - pb.nums[i]
  }
  if (pa.prerelease.length === 0 && pb.prerelease.length === 0) return 0
  if (pa.prerelease.length === 0) return 1
  if (pb.prerelease.length === 0) return -1
  const len = Math.max(pa.prerelease.length, pb.prerelease.length)
  for (let i = 0; i < len; i++) {
    if (pa.prerelease[i] === undefined) return -1
    if (pb.prerelease[i] === undefined) return 1
    const c = compareIdentifier(pa.prerelease[i], pb.prerelease[i])
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
