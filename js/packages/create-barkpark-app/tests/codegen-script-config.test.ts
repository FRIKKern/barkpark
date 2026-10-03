// task-6341e0d95513d0f6: the scaffolder's "Next steps" print `<pm> codegen`,
// and the template script was a bare `barkpark generate`. @barkpark/codegen
// reads a config file ONLY when --config is passed, and the shared
// barkpark.config.ts had no default export, so the real CLI refused with
// "Missing dataset: pass --dataset or set it in barkpark.config." on every
// scaffolded app. This drives the REAL generator into a temp dir, follows the
// script's --config to the file it names, and evaluates that file's default
// export the way codegen's resolveConfig needs it (dataset + output + apiUrl,
// token from the environment).
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import ts from 'typescript'
import { scaffold } from '../src/scaffold'
import { AVAILABLE_TEMPLATES } from '../src/constants'

let tmpRoot: string

beforeAll(async () => {
  tmpRoot = await fs.mkdtemp(path.join(os.tmpdir(), 'cba-codegen-config-'))
})

afterAll(async () => {
  if (tmpRoot) await fs.rm(tmpRoot, { recursive: true, force: true })
})

/** Transpile the generated config and import it with @barkpark/core stubbed out. */
async function loadDefaultExport(
  configPath: string,
  dir: string,
): Promise<Record<string, unknown>> {
  const source = (await fs.readFile(configPath, 'utf8')).replace(
    /import \{ createClient \} from '@barkpark\/core'/,
    'const createClient = (cfg: unknown) => cfg',
  )
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText
  const out = path.join(dir, 'barkpark.config.eval.mjs')
  await fs.writeFile(out, js, 'utf8')
  const mod = (await import(`${pathToFileURL(out).href}?t=${Date.now()}`)) as {
    default?: Record<string, unknown>
  }
  return mod.default ?? {}
}

describe('the scaffolded codegen script can reach a codegen config', () => {
  for (const template of AVAILABLE_TEMPLATES) {
    it(`${template}: \`codegen\` passes --config to a file whose default export codegen accepts`, async () => {
      const dir = path.join(tmpRoot, template)
      await scaffold({ template, targetDir: dir, projectName: 'codegen-fixture', pmCommand: 'npm' })

      const pkg = JSON.parse(await fs.readFile(path.join(dir, 'package.json'), 'utf8')) as {
        scripts: Record<string, string>
      }
      const script = pkg.scripts['codegen'] ?? ''
      const match = /--config\s+(\S+)/.exec(script)
      expect(match, `the codegen script names no --config: "${script}"`).not.toBeNull()

      const configPath = path.join(dir, match![1]!)
      await expect(fs.stat(configPath)).resolves.toBeTruthy()

      process.env['BARKPARK_API_URL'] = 'http://127.0.0.1:4791'
      process.env['BARKPARK_TOKEN'] = 'fixture-token'
      try {
        const cfg = await loadDefaultExport(configPath, dir)
        expect(cfg['dataset']).toBe('production')
        expect(cfg['apiUrl']).toBe('http://127.0.0.1:4791')
        expect(cfg['token']).toBe('fixture-token')
        expect(typeof cfg['output']).toBe('string')
        expect(String(cfg['output'])).toMatch(/\.ts$/)
      } finally {
        delete process.env['BARKPARK_API_URL']
        delete process.env['BARKPARK_TOKEN']
      }
    })
  }
})
