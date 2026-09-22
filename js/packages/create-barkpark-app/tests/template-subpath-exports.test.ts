import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

/**
 * SCAFFOLD SUBPATH-EXPORT ARM (row rpu-backlog-website-starter-migrate).
 *
 * `template-pins.test.ts` guards the VERSION half of "a freshly scaffolded app
 * installs and builds": every `@barkpark/*` pin floor must name a version that
 * exists. It is structurally blind to the SUBPATH half. A template can pin a
 * version that resolves perfectly and still fail `next build` on the first
 * import, because the package at that version does not export the subpath the
 * template reaches for.
 *
 * That is not hypothetical. Measured 2026-09-17 against the live registry:
 *
 *   @barkpark/react@1.0.0-preview.1   exports  .  ./package.json
 *   templates import                           ./client  ./paper-surface.css
 *
 * Two unresolvable subpaths, and NOT ONE of them is visible to any check in
 * this package: `template-pins.test.ts` passes, `website-starter-portabledoc
 * .test.ts` passes, the workspace typechecks — because in the workspace those
 * subpaths both exist. The gap is entirely between the workspace tree and the
 * published tarball. (`@barkpark/nextjs@1.0.0-preview.3` has the same shape of
 * hole at `./csp`; both starters' `lib/csp.ts` already inline their CSP to
 * route around it, and say so in a comment.)
 *
 * This file closes the half that can be closed OFFLINE and deterministically:
 * every `@barkpark/*` subpath a starter template's CODE imports must be a key
 * in that package's own `exports` map in this workspace. That reds the moment
 * a template reaches for a subpath the package does not (or no longer) ship —
 * the shape of the defect, not one instance of it. It is deliberately scoped:
 * it cannot see a subpath that the WORKSPACE exports but the REGISTRY does not
 * (the react case above, and `@barkpark/nextjs/csp` if a template ever reached
 * for it). That is the probe below, not this arm.
 *
 * The registry half cannot be a required CI assertion: it depends on the
 * network, and it is RED TODAY by design (the publish is owner-gated, see
 * rpu-backlog-publish-react-canonical). It ships instead as an explicit,
 * opt-in probe — `CHECK_PUBLISHED_EXPORTS=1 pnpm test` — so the blocker can be
 * re-measured on demand rather than re-derived by hand.
 */

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = resolve(HERE, '..')
const TEMPLATES_DIR = join(PKG_ROOT, 'templates')
const PACKAGES_DIR = resolve(PKG_ROOT, '..')

/** Files a bundler would actually resolve imports out of. `.tmpl` siblings ride along. */
const CODE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.css'])

function isCodeFile(file: string): boolean {
  const stripped = file.endsWith('.tmpl') ? file.slice(0, -'.tmpl'.length) : file
  return CODE_EXT.has(extname(stripped))
}

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) {
      if (entry === 'node_modules' || entry === '.next') continue
      walk(full, out)
    } else if (isCodeFile(entry)) {
      out.push(full)
    }
  }
  return out
}

/**
 * Module specifiers a build would resolve: ES `import`/`export ... from`,
 * bare side-effect `import '…'`, `require('…')`, and CSS `@import '…'`.
 *
 * Deliberately NOT a bare word match. `blog-starter/seeds/showcase-content.ts`
 * says "@barkpark/react/client." in a prose comment, and README.md names every
 * subpath in running text; a word match would report a specifier the build
 * never sees. `extracts specifiers, not prose` pins that distinction.
 */
export function extractSpecifiers(source: string): string[] {
  const found: string[] = []
  const patterns = [
    /(?:^|[\s;}])(?:import|export)\s[^;'"]*?from\s*['"]([^'"]+)['"]/g,
    /(?:^|[\s;}])import\s*['"]([^'"]+)['"]/g,
    /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    /@import\s+(?:url\()?\s*['"]([^'"]+)['"]/g,
  ]
  for (const re of patterns) {
    for (const m of source.matchAll(re)) {
      const spec = m[1]
      if (spec) found.push(spec)
    }
  }
  return found
}

/** `@barkpark/react/client` -> { pkg: '@barkpark/react', subpath: './client' }; bare -> '.'. */
export function splitScoped(
  specifier: string,
): { pkg: string; subpath: string } | null {
  const m = /^(@barkpark\/[a-z0-9][a-z0-9-]*)(?:\/(.+))?$/.exec(specifier)
  const pkg = m?.[1]
  if (!pkg) return null
  const rest = m[2]
  return { pkg, subpath: rest ? `./${rest}` : '.' }
}

/** Every workspace package keyed by its declared name — not by directory guess. */
function workspacePackages(): Map<string, { dir: string; exports: string[]; version: string }> {
  const map = new Map<string, { dir: string; exports: string[]; version: string }>()
  for (const entry of readdirSync(PACKAGES_DIR)) {
    const manifest = join(PACKAGES_DIR, entry, 'package.json')
    let raw: string
    try {
      raw = readFileSync(manifest, 'utf8')
    } catch {
      continue
    }
    const json = JSON.parse(raw) as {
      name?: string
      version?: string
      exports?: Record<string, unknown> | string
    }
    if (!json.name) continue
    const exp =
      json.exports && typeof json.exports === 'object'
        ? Object.keys(json.exports)
        : ['.']
    map.set(json.name, {
      dir: join(PACKAGES_DIR, entry),
      exports: exp,
      version: json.version ?? '0.0.0',
    })
  }
  return map
}

type Usage = { pkg: string; subpath: string; file: string }

function collectUsages(): Usage[] {
  const usages: Usage[] = []
  for (const file of walk(TEMPLATES_DIR)) {
    const source = readFileSync(file, 'utf8')
    for (const spec of extractSpecifiers(source)) {
      const split = splitScoped(spec)
      if (split) {
        usages.push({ ...split, file: relative(PKG_ROOT, file) })
      }
    }
  }
  return usages
}

const USAGES = collectUsages()
const WORKSPACE = workspacePackages()

describe('scaffold templates only import subpaths their package exports', () => {
  it('found subpath imports to check at all', () => {
    // A green with no subject is the failure mode this guards against: a
    // walker that silently returns nothing would pass every assertion below.
    expect(USAGES.length).toBeGreaterThanOrEqual(10)
    const subpathUsages = USAGES.filter((u) => u.subpath !== '.')
    expect(subpathUsages.length).toBeGreaterThanOrEqual(6)
    // Both starters, so a scan that lost a whole template tree cannot pass.
    for (const starter of ['website-starter', 'blog-starter']) {
      expect(
        subpathUsages.some((u) => u.file.includes(`templates/${starter}/`)),
        `no @barkpark subpath imports found under templates/${starter}`,
      ).toBe(true)
    }
    // The three subpaths this row's migration depends on are actually seen.
    const keys = new Set(subpathUsages.map((u) => `${u.pkg}${u.subpath.slice(1)}`))
    expect(keys.has('@barkpark/react/client')).toBe(true)
    expect(keys.has('@barkpark/react/paper-surface.css')).toBe(true)
    // A second package, so a scan that only ever sees @barkpark/react fails.
    expect(
      [...keys].some((k) => k.startsWith('@barkpark/nextjs/')),
      'no @barkpark/nextjs subpath import found in any template',
    ).toBe(true)
  })

  it('every imported @barkpark subpath is a key in that package exports map', () => {
    const offenders: string[] = []
    for (const usage of USAGES) {
      const pkg = WORKSPACE.get(usage.pkg)
      if (!pkg) {
        offenders.push(`${usage.file}: imports unknown package ${usage.pkg}`)
        continue
      }
      if (!pkg.exports.includes(usage.subpath)) {
        offenders.push(
          `${usage.file}: ${usage.pkg} does not export "${usage.subpath}" ` +
            `(exports: ${pkg.exports.join(', ')})`,
        )
      }
    }
    expect(offenders).toEqual([])
  })

  it('discriminates — a subpath the package does not export is reported', () => {
    // Makes the assertion above protective rather than decorative: the same
    // membership test, fed a subpath that is definitely absent, says no.
    const react = WORKSPACE.get('@barkpark/react')
    expect(react, '@barkpark/react not found in the workspace').toBeTruthy()
    expect(react!.exports.includes('./client')).toBe(true)
    expect(react!.exports.includes('./no-such-entrypoint')).toBe(false)
  })

  it('extracts specifiers, not prose', () => {
    const fixture = [
      `import { renderPortableDocument } from '@barkpark/react'`,
      `import { hydratePortableDoc } from "@barkpark/react/client"`,
      `import '@barkpark/react/paper-surface.css'`,
      `const x = require('@barkpark/nextjs/server')`,
      `// see @barkpark/react/client. for the hydration entrypoint`,
      `/* @barkpark/nextjs/definitely-not-imported */`,
    ].join('\n')
    const specs = extractSpecifiers(fixture)
    expect(specs).toContain('@barkpark/react')
    expect(specs).toContain('@barkpark/react/client')
    expect(specs).toContain('@barkpark/react/paper-surface.css')
    expect(specs).toContain('@barkpark/nextjs/server')
    // The two prose mentions carry no quotes, so they are not specifiers.
    expect(specs).not.toContain('@barkpark/react/client.')
    expect(specs).not.toContain('@barkpark/nextjs/definitely-not-imported')
  })

  it('splits scoped specifiers into package and exports key', () => {
    expect(splitScoped('@barkpark/react')).toEqual({
      pkg: '@barkpark/react',
      subpath: '.',
    })
    expect(splitScoped('@barkpark/react/paper-surface.css')).toEqual({
      pkg: '@barkpark/react',
      subpath: './paper-surface.css',
    })
    expect(splitScoped('next/navigation')).toBeNull()
    expect(splitScoped('react')).toBeNull()
  })
})

/**
 * The registry half. Opt-in, because it needs the network AND because it is
 * red today on purpose: @barkpark/react@1.0.0-preview.1 was published before
 * the canonical PortableDoc entrypoints existed, and the workspace still
 * carries that same version number, so shipping them needs a VERSION BUMP and
 * a fresh publish, not a re-publish. Owner-gated.
 *
 *   CHECK_PUBLISHED_EXPORTS=1 pnpm --filter create-barkpark-app test
 */
describe.skipIf(!process.env.CHECK_PUBLISHED_EXPORTS)(
  'published packages export every subpath the templates import',
  () => {
    it('resolves each imported subpath against the registry manifest', async () => {
      const { execFileSync } = await import('node:child_process')
      const needed = new Map<string, Set<string>>()
      for (const usage of USAGES) {
        if (!needed.has(usage.pkg)) needed.set(usage.pkg, new Set())
        needed.get(usage.pkg)!.add(usage.subpath)
      }
      const offenders: string[] = []
      for (const [pkg, subpaths] of needed) {
        const out = execFileSync('npm', ['view', pkg, 'exports', '--json'], {
          encoding: 'utf8',
        })
        const published = out.trim() ? Object.keys(JSON.parse(out)) : ['.']
        for (const subpath of subpaths) {
          if (!published.includes(subpath)) {
            offenders.push(`${pkg} (published) does not export "${subpath}"`)
          }
        }
      }
      expect(offenders).toEqual([])
    }, 120_000)
  },
)
