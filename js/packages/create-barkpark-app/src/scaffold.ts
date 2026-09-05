import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { BARKPARK_VERSION, SHARED_TEMPLATE_DIR, type TemplateName } from './constants.js'

const HERE = path.dirname(fileURLToPath(import.meta.url))

/**
 * SHARED TEMPLATE SOURCE — ownership note.
 *
 * `templates/_shared/` holds the framework boilerplate that every starter needs
 * BYTE-IDENTICALLY, authored ONCE. It was extracted after a duplicate audit
 * measured 16 byte-identical file pairs across blog-starter and website-starter
 * (double-authored, so any ordinary fix had to be applied twice or the two
 * starters silently diverged). The files it owns today:
 *
 *   _gitignore                             next.config.mjs
 *   app/api/barkpark/webhook/route.ts      package.json.tmpl
 *   app/error.tsx                          postcss.config.js
 *   app/globals.css                        tsconfig.json
 *   app/loading.tsx                        barkpark.config.ts.tmpl
 *   app/not-found.tsx                      docker-compose.yml
 *   app/robots.ts                          docker-compose.override.yml.example
 *   lib/format-date.ts                     lib/resolve-server-token.ts
 *
 * Everything else stays in the starter dir because it is INTENTIONALLY VARIANT
 * — it differs today (app/layout.tsx, app/page.tsx, lib/csp.ts, middleware.ts,
 * app/sitemap.ts, tailwind.config.ts, .env.example, README.md, the schemas and
 * seeds) or exists in only one starter. A file only earns a place in _shared
 * when it is byte-identical in EVERY starter AND is framework plumbing rather
 * than product content.
 *
 * COMPOSITION IS BUILD-TIME, NOT RUN-TIME. `scaffold()` lays `_shared` down
 * first and then copies the starter tree OVER it, so a starter can always take
 * a file back by re-adding it under its own dir. The generated app is a plain
 * self-contained tree: nothing it contains refers to `_shared`, and the
 * directory is not copied into the output.
 *
 * The cloud mirror (`cloud/priv/templates/<slug>`) is composed the same way by
 * `scripts/sync-starter-templates.mjs`, so the deploy button pushes exactly
 * what this scaffolder writes.
 */

export interface ScaffoldOptions {
  template: TemplateName
  targetDir: string
  projectName: string
  pmCommand: string
}

export interface ScaffoldResult {
  filesWritten: number
  templateDir: string
  empty: boolean
}

export async function scaffold(opts: ScaffoldOptions): Promise<ScaffoldResult> {
  const templatesRoot = path.resolve(HERE, '..', 'templates')
  const templateDir = path.join(templatesRoot, opts.template)
  const sharedDir = path.join(templatesRoot, SHARED_TEMPLATE_DIR)

  await assertTemplateExists(templateDir, opts.template)
  await assertTemplateExists(sharedDir, SHARED_TEMPLATE_DIR)

  await fs.mkdir(opts.targetDir, { recursive: true })

  const vars: Record<string, string> = {
    projectName: opts.projectName,
    packageName: toPackageName(opts.projectName),
    pmCommand: opts.pmCommand,
    barkparkVersion: BARKPARK_VERSION,
  }

  // _shared FIRST, then the starter tree over it: a starter file with the same
  // destination path wins, and the destination-keyed count below never
  // double-counts an overridden file.
  const stats = { written: 0 }
  const seen = new Set<string>()
  await copyTree(sharedDir, opts.targetDir, vars, stats, seen)
  await copyTree(templateDir, opts.targetDir, vars, stats, seen)

  return {
    filesWritten: stats.written,
    templateDir,
    empty: stats.written === 0,
  }
}

async function assertTemplateExists(dir: string, name: string): Promise<void> {
  try {
    const st = await fs.stat(dir)
    if (!st.isDirectory()) {
      throw new Error(`Template path is not a directory: ${dir}`)
    }
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new Error(`Template "${name}" not found at ${dir}`)
    }
    throw err
  }
}

async function copyTree(
  srcDir: string,
  destDir: string,
  vars: Record<string, string>,
  stats: { written: number },
  seen: Set<string>,
  relPrefix = '',
): Promise<void> {
  const entries = await fs.readdir(srcDir, { withFileTypes: true })
  await fs.mkdir(destDir, { recursive: true })

  for (const entry of entries) {
    const srcPath = path.join(srcDir, entry.name)
    let destName = entry.name

    if (destName === '_gitignore') destName = '.gitignore'
    else if (destName === '_npmrc') destName = '.npmrc'

    if (entry.isDirectory()) {
      await copyTree(
        srcPath,
        path.join(destDir, destName),
        vars,
        stats,
        seen,
        relPrefix ? `${relPrefix}/${destName}` : destName,
      )
      continue
    }

    if (!entry.isFile()) continue
    if (entry.name === '.gitkeep') continue

    const isTmpl = destName.endsWith('.tmpl')
    if (isTmpl) destName = destName.slice(0, -'.tmpl'.length)

    const destPath = path.join(destDir, destName)
    const rel = relPrefix ? `${relPrefix}/${destName}` : destName

    if (isTmpl || isTextFile(entry.name)) {
      const raw = await fs.readFile(srcPath, 'utf8')
      const rendered = renderTemplate(raw, vars)
      await fs.writeFile(destPath, rendered, 'utf8')
    } else {
      await fs.copyFile(srcPath, destPath)
    }
    if (!seen.has(rel)) {
      seen.add(rel)
      stats.written++
    }
  }
}

function isTextFile(name: string): boolean {
  return /\.(ts|tsx|js|jsx|mjs|cjs|json|md|mdx|yml|yaml|env|example|gitignore|npmrc|css|html|txt)$/i.test(
    name,
  )
}

/**
 * Names npm refuses outright. `_` and `.` are legal inside a package name, so
 * `node_modules` and `favicon.ico` survive slugification byte-for-byte — and
 * both are hard-invalid (validate-npm-package-name v7:
 * `validForOldPackages: false`). npm/pnpm/bun install them anyway, but yarn
 * classic exits 1 with "error package.json: Name is blacklisted", and pm.ts
 * can select yarn from the user agent. Pinned to npm 11 / v7 behaviour; the
 * blacklist may move between npm majors.
 */
const BLACKLISTED_PACKAGE_NAMES = new Set(['node_modules', 'favicon.ico'])

/** npm's name-length ceiling. Over it is a WARNING everywhere (install and
 * publish both exit 0), so this clamp is hardening, not an error fix — unlike
 * the blacklist above, which is a real npm error. */
const MAX_PACKAGE_NAME_LENGTH = 214

/**
 * Turn a project name into a valid npm package "name": lowercase, non-URL-safe
 * runs collapsed to '-', no leading '.'/'_', never empty, never blacklisted,
 * and never over npm's 214-character ceiling.
 */
export function toPackageName(name: string): string {
  const slug = String(name)
    .toLowerCase()
    .replace(/[^a-z0-9-_.]+/g, '-')
    .replace(/^[._]+/, '')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) return 'barkpark-site'
  const safe = BLACKLISTED_PACKAGE_NAMES.has(slug) ? `${slug}-app` : slug
  return safe.length <= MAX_PACKAGE_NAME_LENGTH
    ? safe
    : // re-trim: the cut can land on a '-' or '.', which npm dislikes trailing
      safe.slice(0, MAX_PACKAGE_NAME_LENGTH).replace(/[-.]+$/, '')
}

export function renderTemplate(input: string, vars: Record<string, string>): string {
  return input.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, key: string) => {
    return Object.prototype.hasOwnProperty.call(vars, key) ? vars[key]! : `{{${key}}}`
  })
}
