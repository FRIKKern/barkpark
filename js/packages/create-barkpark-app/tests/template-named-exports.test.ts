import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { describe, expect, it } from 'vitest'

/**
 * SCAFFOLD NAMED-EXPORT ARM (task-98d983344aec5edd, owner item 54).
 *
 * `template-subpath-exports.test.ts` checks that every `@barkpark/*` SUBPATH a
 * starter imports is a key in that package's `exports` map. It cannot see the
 * NAME half: `import { barkparkMetadata } from '@barkpark/nextjs'` resolves the
 * `.` subpath, which every version has always exported, so the subpath arm is
 * green whether or not the entry behind `.` exports `barkparkMetadata`.
 *
 * This arm closes that half against the SOURCE, offline. For every named
 * import (and `export { … } from`) of an `@barkpark/*` specifier in a starter
 * template, it:
 *   1. looks the subpath up in the package's own `exports` map and takes EVERY
 *      runtime target the map names for it (`import`, `default`, and
 *      `react-server` where present — a Server Component resolves the
 *      `react-server` target, a client component the `import` one);
 *   2. maps each `./dist/<entry>.mjs` target back to its source file through
 *      the package's own `tsup.config.ts` `entry` map;
 *   3. asks the TypeScript checker for that source entry's exported names.
 * A template file with a `'use client'` directive is checked against the
 * `import` target only; any other file against every target, because a
 * directive-free module is evaluated in the RSC graph.
 *
 * WHAT IT CANNOT SEE — and owner item 54 is exactly this: a name the workspace
 * source exports but a PUBLISHED version does not. `barkparkMetadata` has been
 * in `src/index.ts` since #963; `@barkpark/nextjs@1.0.0-preview.3` on npm was
 * built from 0c81beeb1 two months earlier. That gap is closed by publishing,
 * not by a test; the opt-in registry probe in template-subpath-exports.test.ts
 * re-measures the subpath half of it on demand.
 */

const HERE = dirname(fileURLToPath(import.meta.url))
const PKG_ROOT = resolve(HERE, '..')
const TEMPLATES_DIR = join(PKG_ROOT, 'templates')
const PACKAGES_DIR = resolve(PKG_ROOT, '..')

const CODE_EXT = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'])

function stripTmpl(file: string): string {
  return file.endsWith('.tmpl') ? file.slice(0, -'.tmpl'.length) : file
}

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    if (statSync(full).isDirectory()) {
      if (entry === 'node_modules' || entry === '.next') continue
      walk(full, out)
    } else if (CODE_EXT.has(extname(stripTmpl(entry)))) {
      out.push(full)
    }
  }
  return out
}

export type NamedImport = {
  specifier: string
  name: string
  typeOnly: boolean
  useClient: boolean
}

/** Named imports / re-exports of `@barkpark/*` specifiers, read from the AST (never from prose). */
export function extractNamedImports(fileName: string, source: string): NamedImport[] {
  const sf = ts.createSourceFile(fileName, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const first = sf.statements[0]
  const useClient =
    first !== undefined &&
    ts.isExpressionStatement(first) &&
    ts.isStringLiteral(first.expression) &&
    first.expression.text === 'use client'
  const out: NamedImport[] = []
  for (const stmt of sf.statements) {
    if (ts.isImportDeclaration(stmt) && ts.isStringLiteral(stmt.moduleSpecifier)) {
      const specifier = stmt.moduleSpecifier.text
      if (!specifier.startsWith('@barkpark/')) continue
      const clause = stmt.importClause
      if (!clause) continue
      if (clause.name) {
        out.push({ specifier, name: 'default', typeOnly: clause.isTypeOnly, useClient })
      }
      const bindings = clause.namedBindings
      if (bindings && ts.isNamedImports(bindings)) {
        for (const el of bindings.elements) {
          out.push({
            specifier,
            name: (el.propertyName ?? el.name).text,
            typeOnly: clause.isTypeOnly || el.isTypeOnly,
            useClient,
          })
        }
      }
    } else if (
      ts.isExportDeclaration(stmt) &&
      stmt.moduleSpecifier &&
      ts.isStringLiteral(stmt.moduleSpecifier) &&
      stmt.moduleSpecifier.text.startsWith('@barkpark/') &&
      stmt.exportClause &&
      ts.isNamedExports(stmt.exportClause)
    ) {
      for (const el of stmt.exportClause.elements) {
        out.push({
          specifier: stmt.moduleSpecifier.text,
          name: (el.propertyName ?? el.name).text,
          typeOnly: stmt.isTypeOnly || el.isTypeOnly,
          useClient,
        })
      }
    }
  }
  return out
}

function splitScoped(specifier: string): { pkg: string; subpath: string } | null {
  const m = /^(@barkpark\/[a-z0-9][a-z0-9-]*)(?:\/(.+))?$/.exec(specifier)
  if (!m?.[1]) return null
  return { pkg: m[1], subpath: m[2] ? `./${m[2]}` : '.' }
}

type Target = { condition: string; dist: string }

/** Every runtime (non-`types`) target an exports-map entry names, keyed by the condition path to it. */
function runtimeTargets(entry: unknown, path = ''): Target[] {
  if (typeof entry === 'string') return [{ condition: path || 'default', dist: entry }]
  if (!entry || typeof entry !== 'object') return []
  const out: Target[] = []
  for (const [cond, value] of Object.entries(entry as Record<string, unknown>)) {
    if (cond === 'types' || cond === 'require') continue
    out.push(...runtimeTargets(value, path ? `${path}.${cond}` : cond))
  }
  return out
}

type Workspace = Map<
  string,
  { dir: string; exports: Record<string, unknown>; tsupEntry: Map<string, string> }
>

function workspace(): Workspace {
  const map: Workspace = new Map()
  for (const dirName of readdirSync(PACKAGES_DIR)) {
    const dir = join(PACKAGES_DIR, dirName)
    let json: { name?: string; exports?: Record<string, unknown> }
    try {
      json = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'))
    } catch {
      continue
    }
    if (!json.name?.startsWith('@barkpark/') || !json.exports) continue
    const tsupEntry = new Map<string, string>()
    try {
      const cfg = readFileSync(join(dir, 'tsup.config.ts'), 'utf8')
      const block = /entry:\s*\{([^}]*)\}/.exec(cfg)?.[1] ?? ''
      for (const m of block.matchAll(/['"]?([\w-]+)['"]?\s*:\s*['"](src\/[^'"]+)['"]/g)) {
        if (m[1] && m[2]) tsupEntry.set(m[1], join(dir, m[2]))
      }
    } catch {
      // no tsup config: tsupEntry stays empty and every lookup below reports it
    }
    map.set(json.name, { dir, exports: json.exports, tsupEntry })
  }
  return map
}

const WS = workspace()

type Usage = NamedImport & { file: string }

const USAGES: Usage[] = walk(TEMPLATES_DIR).flatMap((file) =>
  extractNamedImports(stripTmpl(file), readFileSync(file, 'utf8')).map((u) => ({
    ...u,
    file: relative(PKG_ROOT, file),
  })),
)

/** Source entry files every usage needs, resolved once so one Program serves them all. */
function sourceFor(pkg: string, dist: string): string | undefined {
  const m = /^\.\/dist\/([\w-]+)\.m?js$/.exec(dist)
  return m?.[1] ? WS.get(pkg)?.tsupEntry.get(m[1]) : undefined
}

const ENTRY_FILES = new Set<string>()
for (const u of USAGES) {
  const split = splitScoped(u.specifier)
  const exp = split && WS.get(split.pkg)?.exports[split.subpath]
  if (!split || !exp) continue
  for (const t of runtimeTargets(exp)) {
    const src = sourceFor(split.pkg, t.dist)
    if (src) ENTRY_FILES.add(src)
  }
}

const PROGRAM = ts.createProgram([...ENTRY_FILES], {
  target: ts.ScriptTarget.ES2022,
  module: ts.ModuleKind.ESNext,
  moduleResolution: ts.ModuleResolutionKind.Bundler,
  jsx: ts.JsxEmit.ReactJSX,
  skipLibCheck: true,
  noEmit: true,
  allowJs: true,
  resolveJsonModule: true,
})
const CHECKER = PROGRAM.getTypeChecker()
const EXPORT_CACHE = new Map<string, Map<string, boolean>>()

/** name -> isValue, for every export of a source entry (follows `export *` and aliases). */
function exportsOf(file: string): Map<string, boolean> | undefined {
  const cached = EXPORT_CACHE.get(file)
  if (cached) return cached
  const sf = PROGRAM.getSourceFile(file)
  const sym = sf && CHECKER.getSymbolAtLocation(sf)
  if (!sym) return undefined
  const names = new Map<string, boolean>()
  for (const e of CHECKER.getExportsOfModule(sym)) {
    const target = e.flags & ts.SymbolFlags.Alias ? CHECKER.getAliasedSymbol(e) : e
    names.set(e.getName(), (target.flags & ts.SymbolFlags.Value) !== 0)
  }
  EXPORT_CACHE.set(file, names)
  return names
}

/** Offender lines for a set of usages; empty when every name is exported by every target it can resolve to. */
function offendersFor(usages: Usage[]): string[] {
  const out: string[] = []
  for (const u of usages) {
    const split = splitScoped(u.specifier)
    const pkg = split && WS.get(split.pkg)
    const exp = split && pkg?.exports[split.subpath]
    if (!split || !pkg || !exp) {
      out.push(
        `${u.file}: ${u.specifier} is not a workspace package subpath (template-subpath-exports.test.ts owns this)`,
      )
      continue
    }
    const seen = new Set<string>()
    const targets = runtimeTargets(exp).filter(
      (t) =>
        (!u.useClient || !t.condition.startsWith('react-server')) &&
        !seen.has(t.dist) &&
        !!seen.add(t.dist),
    )
    for (const t of targets) {
      const src = sourceFor(split.pkg, t.dist)
      const names = src ? exportsOf(src) : undefined
      if (!src || !names) {
        out.push(
          `${u.file}: ${u.specifier} [${t.condition}] -> ${t.dist} has no tsup entry source to read`,
        )
        continue
      }
      const isValue = names.get(u.name)
      if (isValue === undefined) {
        out.push(
          `${u.file}: imports { ${u.name} } from '${u.specifier}', but ${relative(PACKAGES_DIR, src)} ` +
            `(the [${t.condition}] target ${t.dist}) does not export it`,
        )
      } else if (!u.typeOnly && !isValue) {
        out.push(
          `${u.file}: value-imports { ${u.name} } from '${u.specifier}', but [${t.condition}] exports it as a type only`,
        )
      }
    }
  }
  return out
}

describe('scaffold templates only import names their @barkpark entry exports', () => {
  it('has a subject: both starters, several packages, and the item-54 name are seen', () => {
    expect(USAGES.length).toBeGreaterThanOrEqual(15)
    for (const starter of ['website-starter', 'blog-starter']) {
      expect(
        USAGES.some((u) => u.file.includes(`templates/${starter}/`)),
        starter,
      ).toBe(true)
    }
    const pkgs = new Set(USAGES.map((u) => splitScoped(u.specifier)?.pkg))
    for (const p of ['@barkpark/core', '@barkpark/nextjs', '@barkpark/react']) {
      expect(pkgs.has(p), p).toBe(true)
    }
    expect(
      USAGES.some((u) => u.name === 'barkparkMetadata' && u.specifier === '@barkpark/nextjs'),
    ).toBe(true)
    expect(
      USAGES.some(
        (u) => u.name === 'hydratePortableDoc' && u.specifier === '@barkpark/react/client',
      ),
    ).toBe(true)
    // Every entry file the usages point at was actually loaded and read.
    expect(ENTRY_FILES.size).toBeGreaterThanOrEqual(5)
    for (const f of ENTRY_FILES) expect(exportsOf(f)?.size ?? 0, f).toBeGreaterThan(0)
  })

  it('every named @barkpark import is exported by every entry it can resolve to', () => {
    expect(offendersFor(USAGES)).toEqual([])
  })

  it('discriminates — a name the entry does not export is reported, per condition', () => {
    const base = { file: 'fixture.tsx', typeOnly: false }
    const missing = offendersFor([
      { ...base, specifier: '@barkpark/nextjs', name: 'noSuchExport', useClient: false },
    ])
    expect(missing).toHaveLength(1)
    expect(missing[0]).toContain('does not export it')
    // The react root has a `react-server` target AND an `import` target; a
    // directive-free file is checked against both, a 'use client' file only
    // against `import`.
    const both = offendersFor([
      { ...base, specifier: '@barkpark/react', name: 'noSuchExport', useClient: false },
    ])
    expect(both.some((l) => l.includes('[react-server.'))).toBe(true)
    expect(both.some((l) => l.includes('[import.'))).toBe(true)
    expect(both).toHaveLength(2)
    const client = offendersFor([
      { ...base, specifier: '@barkpark/react', name: 'noSuchExport', useClient: true },
    ])
    expect(client.some((l) => l.includes('[react-server.'))).toBe(false)
    expect(client).toHaveLength(1)
  })

  it('reads named imports from the AST, not from prose or strings', () => {
    const src = [
      `'use client'`,
      `import { a, b as c, type T } from '@barkpark/nextjs'`,
      `import type { U } from '@barkpark/core'`,
      `import '@barkpark/react/paper-surface.css'`,
      `export { d } from '@barkpark/react'`,
      `// import { prose } from '@barkpark/nextjs'`,
      `const s = "import { str } from '@barkpark/nextjs'"`,
    ].join('\n')
    const got = extractNamedImports('f.tsx', src)
    expect(got.map((g) => `${g.specifier}:${g.name}:${g.typeOnly}`)).toEqual([
      '@barkpark/nextjs:a:false',
      '@barkpark/nextjs:b:false',
      '@barkpark/nextjs:T:true',
      '@barkpark/core:U:true',
      '@barkpark/react:d:false',
    ])
    expect(got.every((g) => g.useClient)).toBe(true)
  })
})
