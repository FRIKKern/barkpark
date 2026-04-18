import { describe, it, expect, afterAll } from 'vitest'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, existsSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const CLI = resolve(__dirname, '..', 'dist', 'cli.mjs')
const FIXTURE = resolve(__dirname, 'fixtures', 'schema.json')

const scratchPaths: string[] = []
function scratch(prefix: string): string {
  const p = mkdtempSync(join(tmpdir(), prefix))
  scratchPaths.push(p)
  return p
}

afterAll(() => {
  for (const p of scratchPaths) {
    rmSync(p, { recursive: true, force: true })
  }
})

describe('CLI smoke', () => {
  it('--help exits 0 and lists commands', () => {
    const r = spawnSync('node', [CLI, '--help'], { encoding: 'utf8' })
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/init/)
    expect(r.stdout).toMatch(/schema extract/)
    expect(r.stdout).toMatch(/codegen/)
    expect(r.stdout).toMatch(/check/)
  })

  it('--version exits 0 and prints a version', () => {
    const r = spawnSync('node', [CLI, '--version'], { encoding: 'utf8' })
    expect(r.status).toBe(0)
    expect(r.stdout).toMatch(/\d+\.\d+\.\d+/)
  })

  it('init --cwd writes barkpark.config.ts', () => {
    const dir = scratch('bp-test-init-')
    const r = spawnSync('node', [CLI, 'init', '--cwd', dir], { encoding: 'utf8' })
    expect(r.status, r.stderr).toBe(0)
    const cfg = join(dir, 'barkpark.config.ts')
    expect(existsSync(cfg)).toBe(true)
    expect(readFileSync(cfg, 'utf8')).toContain('defineConfig')
  })

  it('codegen --in <fixture> writes a typed module with header', () => {
    const dir = scratch('bp-test-out-')
    const out = join(dir, 'types.ts')
    const r = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier'],
      { encoding: 'utf8' },
    )
    expect(r.status, r.stderr).toBe(0)
    expect(existsSync(out)).toBe(true)
    const body = readFileSync(out, 'utf8')
    expect(body).toContain('// AUTO-GENERATED')
    expect(body).toContain('// @barkpark-schema-hash:')
    expect(body).toContain('export interface Post {')
  })
})
