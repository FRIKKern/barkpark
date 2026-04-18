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
  return /\.(ts|tsx|js|jsx|mjs|cjs|json|md|mdx|yml|yaml|env|example|gitignore|npmrc|css|html|txt)$/i.test(name)
}

export function renderTemplate(input: string, vars: Record<string, string>): string {
  return input.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (_, key: string) => {
    return Object.prototype.hasOwnProperty.call(vars, key) ? vars[key]! : `{{${key}}}`
  })
}
