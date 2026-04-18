import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const CLI = resolve(__dirname, '..', 'dist', 'cli.mjs')
const FIXTURE = resolve(__dirname, 'fixtures', 'schema.json')

let scratch: string
let out: string

beforeEach(() => {
  scratch = mkdtempSync(join(tmpdir(), 'bp-test-check-'))
  out = join(scratch, 'barkpark.types.ts')
})

afterEach(() => {
  rmSync(scratch, { recursive: true, force: true })
})

describe('CLI --check drift detection', () => {
  it('Case A: first generate, then --check exits 0 with "no drift"', () => {
    const gen = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier'],
      { encoding: 'utf8' },
    )
    expect(gen.status, gen.stderr).toBe(0)
    expect(existsSync(out)).toBe(true)

    const check = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier', '--check'],
      { encoding: 'utf8' },
    )
    expect(check.status).toBe(0)
    expect(check.stdout).toMatch(/no drift/)
  })

  it('Case B: tampered output → --check exits 1 with diff', () => {
    const gen = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier'],
      { encoding: 'utf8' },
    )
    expect(gen.status, gen.stderr).toBe(0)

    const original = readFileSync(out, 'utf8')
    writeFileSync(out, original + '// tampered\n', 'utf8')

    const check = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier', '--check'],
      { encoding: 'utf8' },
    )
    expect(check.status).toBe(1)
    expect(check.stderr).toMatch(/drift/)
    // The diff should flag the tampered line.
    expect(check.stderr).toMatch(/tampered/)
  })

  it('Case C: --check with missing output file → exit 1', () => {
    const check = spawnSync(
      'node',
      [CLI, 'codegen', '--in', FIXTURE, '--out', out, '--no-prettier', '--check'],
      { encoding: 'utf8' },
    )
    expect(check.status).toBe(1)
    expect(check.stderr).toMatch(/does not exist/)
  })
})
