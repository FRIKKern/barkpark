import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { BARKPARK_VERSION, type TemplateName } from './constants.js'

const HERE = path.dirname(fileURLToPath(import.meta.url))

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
  const templateDir = path.resolve(HERE, '..', 'templates', opts.template)

  await assertTemplateExists(templateDir, opts.template)

  await fs.mkdir(opts.targetDir, { recursive: true })

  const vars: Record<string, string> = {
    projectName: opts.projectName,
    packageName: toPackageName(opts.projectName),
    pmCommand: opts.pmCommand,
    barkparkVersion: BARKPARK_VERSION,
  }

  const stats = { written: 0 }
  await copyTree(templateDir, opts.targetDir, vars, stats)

  return {
    filesWritten: stats.written,
    templateDir,
    empty: stats.written === 0,
  }
}

async function assertTemplateExists(dir: string, name: TemplateName): Promise<void> {
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
): Promise<void> {
  const entries = await fs.readdir(srcDir, { withFileTypes: true })
  await fs.mkdir(destDir, { recursive: true })

  for (const entry of entries) {
    const srcPath = path.join(srcDir, entry.name)
    let destName = entry.name

    if (destName === '_gitignore') destName = '.gitignore'
    else if (destName === '_npmrc') destName = '.npmrc'

    if (entry.isDirectory()) {
      await copyTree(srcPath, path.join(destDir, destName), vars, stats)
      continue
    }

    if (!entry.isFile()) continue
    if (entry.name === '.gitkeep') continue

    const isTmpl = destName.endsWith('.tmpl')
    if (isTmpl) destName = destName.slice(0, -'.tmpl'.length)

    const destPath = path.join(destDir, destName)

    if (isTmpl || isTextFile(entry.name)) {
      const raw = await fs.readFile(srcPath, 'utf8')
      const rendered = renderTemplate(raw, vars)
      await fs.writeFile(destPath, rendered, 'utf8')
    } else {
      await fs.copyFile(srcPath, destPath)
    }
    stats.written++
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
