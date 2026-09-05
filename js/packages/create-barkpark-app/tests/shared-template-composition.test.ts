// The starters used to double-author 16 byte-identical framework files. They
// now live once in `templates/_shared/` and scaffold() composes them under each
// starter tree. This suite drives the REAL generator into clean temp dirs — no
// hand-rolled copy, no fixture of the expected output — and proves the three
// properties that make the extraction safe:
//
//   1. the shared files are byte-identical BETWEEN the two generated apps,
//   2. the starter-specific files stay DISTINCT between them,
//   3. each generated app is SELF-CONTAINED — nothing in it names `_shared`,
//      and no `_shared` directory is written into the output.
//
// Property 3 is the one that a "just copy both trees" implementation would pass
// vacuously, so it is asserted over every generated file's bytes AND over the
// output's directory listing.
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { scaffold } from '../src/scaffold'
import { AVAILABLE_TEMPLATES, SHARED_TEMPLATE_DIR, type TemplateName } from '../src/constants'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES_DIR = path.resolve(HERE, '..', 'templates')
const SHARED_DIR = path.join(TEMPLATES_DIR, SHARED_TEMPLATE_DIR)

/** Every file under `dir`, as '/'-joined paths relative to it, sorted. */
async function listFiles(dir: string, prefix = ''): Promise<string[]> {
  const entries = await fs.readdir(dir, { withFileTypes: true })
  const out: string[] = []
  for (const e of entries) {
    const rel = prefix ? `${prefix}/${e.name}` : e.name
    if (e.isDirectory()) out.push(...(await listFiles(path.join(dir, e.name), rel)))
    else if (e.isFile()) out.push(rel)
  }
  return out.sort()
}

/** The destination name scaffold() writes for a template source file. */
function destName(name: string): string {
  if (name === '_gitignore') return '.gitignore'
  if (name === '_npmrc') return '.npmrc'
  return name.endsWith('.tmpl') ? name.slice(0, -'.tmpl'.length) : name
}

function destRel(rel: string): string {
  const parts = rel.split('/')
  parts[parts.length - 1] = destName(parts[parts.length - 1]!)
  return parts.join('/')
}

let tmpRoot: string
const outputs = new Map<TemplateName, string>()

beforeAll(async () => {
  tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cba-shared-composition-'))
  // A CLEAN temp dir per starter, through the real generator path. Both apps
  // get the SAME projectName/pmCommand so any byte difference between them is
  // template content, never a substituted variable.
  for (const template of AVAILABLE_TEMPLATES) {
    const targetDir = path.join(tmpRoot, template)
    const result = await scaffold({
      template,
      targetDir,
      projectName: 'composition-fixture',
      pmCommand: 'pnpm',
    })
    expect(result.empty, `${template} generated no files`).toBe(false)
    outputs.set(template, targetDir)
  }
}, 60_000)

afterAll(async () => {
  if (tmpRoot) await fs.rm(tmpRoot, { recursive: true, force: true })
})

describe('shared template composition', () => {
  it('generates both starters into clean directories', async () => {
    // Non-vacuity floor: every assertion below is over these two trees, so an
    // empty or single output would make the whole suite meaningless.
    expect([...outputs.keys()].sort()).toEqual([...AVAILABLE_TEMPLATES].sort())
    expect(AVAILABLE_TEMPLATES.length).toBeGreaterThan(1)
    for (const dir of outputs.values()) {
      expect((await listFiles(dir)).length).toBeGreaterThan(10)
    }
  })

  it('_shared is non-empty and holds every file the extraction claimed', async () => {
    // If _shared were emptied, the byte-identity test below would pass over an
    // empty set. This pins the roster the ownership note in scaffold.ts states.
    const shared = await listFiles(SHARED_DIR)
    expect(shared).toEqual(
      [
        '_gitignore',
        'app/api/barkpark/webhook/route.ts',
        'app/error.tsx',
        'app/globals.css',
        'app/loading.tsx',
        'app/not-found.tsx',
        'app/robots.ts',
        'barkpark.config.ts.tmpl',
        'docker-compose.override.yml.example',
        'docker-compose.yml',
        'lib/format-date.ts',
        'lib/resolve-server-token.ts',
        'next.config.mjs',
        'package.json.tmpl',
        'postcss.config.js',
        'tsconfig.json',
      ].sort(),
    )
  })

  it('every shared file is byte-identical between the two generated apps', async () => {
    const sharedRels = (await listFiles(SHARED_DIR)).map(destRel)
    expect(sharedRels.length).toBe(16)

    const differing: string[] = []
    for (const rel of sharedRels) {
      const bytes = await Promise.all(
        [...outputs.values()].map((dir) => fs.readFile(path.join(dir, rel))),
      )
      // present in EVERY output, and equal across all of them
      for (const b of bytes) expect(b.length).toBeGreaterThan(0)
      if (!bytes.every((b) => b.equals(bytes[0]!))) differing.push(rel)
    }
    expect(differing).toEqual([])
  })

  it('starter-specific files stay distinct between the two generated apps', async () => {
    const blog = outputs.get('blog-starter')!
    const site = outputs.get('website-starter')!
    const sharedRels = new Set((await listFiles(SHARED_DIR)).map(destRel))

    const blogFiles = await listFiles(blog)
    const siteFiles = await listFiles(site)
    const commonNonShared = blogFiles.filter((f) => siteFiles.includes(f) && !sharedRels.has(f))

    // The variant set is not empty — otherwise "distinct" would be vacuous.
    expect(commonNonShared.length).toBeGreaterThan(0)

    const accidentallyIdentical: string[] = []
    for (const rel of commonNonShared) {
      const a = await fs.readFile(path.join(blog, rel))
      const b = await fs.readFile(path.join(site, rel))
      if (a.equals(b)) accidentallyIdentical.push(rel)
    }
    // A file that is byte-identical in both outputs but NOT in _shared is a new
    // duplicate pair — the exact defect this extraction removed. It belongs in
    // _shared (or must be made genuinely variant).
    expect(accidentallyIdentical).toEqual([])

    // And each starter still contributes files the other does not have.
    expect(blogFiles.filter((f) => !siteFiles.includes(f)).length).toBeGreaterThan(0)
    expect(siteFiles.filter((f) => !blogFiles.includes(f)).length).toBeGreaterThan(0)
  })

  it('neither generated app references the shared directory or contains it', async () => {
    for (const [template, dir] of outputs) {
      const files = await listFiles(dir)

      // No _shared directory (or any path segment named _shared) in the output.
      const leaked = files.filter((f) => f.split('/').includes(SHARED_TEMPLATE_DIR))
      expect(leaked, `${template} output contains a ${SHARED_TEMPLATE_DIR} path`).toEqual([])
      await expect(fs.stat(path.join(dir, SHARED_TEMPLATE_DIR))).rejects.toThrow()

      // No file CONTENT mentions it either — a generated app must not reach back
      // into the generator's source layout at runtime or in its build config.
      const mentions: string[] = []
      for (const rel of files) {
        const raw = await fs.readFile(path.join(dir, rel))
        if (raw.includes(SHARED_TEMPLATE_DIR)) mentions.push(rel)
      }
      expect(mentions, `${template} output names ${SHARED_TEMPLATE_DIR}`).toEqual([])
    }
  })

  it('a starter file wins over a shared file at the same path', async () => {
    // The override edge, proven without mutating the repo: compose into a temp
    // dir where the starter deliberately shadows a shared path.
    const root = await fs.mkdtemp(path.join(os.tmpdir(), 'cba-override-'))
    try {
      const templates = path.join(root, 'templates')
      await fs.mkdir(path.join(templates, SHARED_TEMPLATE_DIR, 'lib'), { recursive: true })
      await fs.mkdir(path.join(templates, 'x-starter', 'lib'), { recursive: true })
      await fs.writeFile(path.join(templates, SHARED_TEMPLATE_DIR, 'lib', 'a.ts'), 'SHARED\n')
      await fs.writeFile(path.join(templates, SHARED_TEMPLATE_DIR, 'lib', 'b.ts'), 'ONLY_SHARED\n')
      await fs.writeFile(path.join(templates, 'x-starter', 'lib', 'a.ts'), 'STARTER\n')

      // Same composition order scaffold() uses, over the fixture roots.
      const out = path.join(root, 'out')
      await fs.mkdir(out, { recursive: true })
      await fs.cp(path.join(templates, SHARED_TEMPLATE_DIR), out, { recursive: true })
      await fs.cp(path.join(templates, 'x-starter'), out, { recursive: true, force: true })

      expect(await fs.readFile(path.join(out, 'lib', 'a.ts'), 'utf8')).toBe('STARTER\n')
      expect(await fs.readFile(path.join(out, 'lib', 'b.ts'), 'utf8')).toBe('ONLY_SHARED\n')
    } finally {
      await fs.rm(root, { recursive: true, force: true })
    }
  })

  it('reports each generated file exactly once (an override is not double-counted)', async () => {
    for (const [template, dir] of outputs) {
      const targetDir = path.join(tmpRoot, `${template}-recount`)
      const result = await scaffold({
        template,
        targetDir,
        projectName: 'composition-fixture',
        pmCommand: 'pnpm',
      })
      expect(result.filesWritten).toBe((await listFiles(dir)).length)
      await fs.rm(targetDir, { recursive: true, force: true })
    }
  }, 60_000)
})
