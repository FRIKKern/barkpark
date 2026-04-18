import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { emit } from '../src/codegen/emit.js'
import type { RawSchemaDoc } from '../src/types.js'

const FIXTURE_PATH = resolve(__dirname, 'fixtures', 'schema.json')
const GOLDEN_PATH = resolve(__dirname, 'fixtures', 'expected.types.ts')

function loadFixture(): RawSchemaDoc {
  return JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as RawSchemaDoc
}

/**
 * Extract each `export interface X { ... }` block from a source string.
 * Returns a Map<typeName, block-body-string>.
 */
function extractInterfaces(source: string): Map<string, string> {
  const out = new Map<string, string>()
  const re = /export interface (\w+) \{\n([\s\S]*?)\n\}/g
  let m: RegExpExecArray | null
  while ((m = re.exec(source)) !== null) {
    out.set(m[1]!, m[2]!)
  }
  return out
}

function extractFieldUnions(source: string): Map<string, string> {
  const out = new Map<string, string>()
  const re = /export type (\w+Field) = ([^;]+);/g
  let m: RegExpExecArray | null
  while ((m = re.exec(source)) !== null) {
    out.set(m[1]!, m[2]!.trim())
  }
  return out
}

function extractFilters(source: string): Map<string, string> {
  const out = new Map<string, string>()
  const re = /export type (\w+Filter) = \{\n([\s\S]*?)\n\};/g
  let m: RegExpExecArray | null
  while ((m = re.exec(source)) !== null) {
    out.set(m[1]!, m[2]!)
  }
  return out
}

describe('emit — strict mode, fixture', () => {
  const doc = loadFixture()
  const out = emit(doc, {
    loose: false,
    schemaHash: 'X',
    source: '/v1/schemas/production',
  })

  it('stamps expected header markers', () => {
    expect(out).toContain('// AUTO-GENERATED')
    expect(out).toContain('// @barkpark-schema-hash: X')
    expect(out).toContain('// codegen-version: 0.1.0')
    expect(out).toContain('// mode: strict')
    expect(out).toContain(
      '// schemas: author, category, colors, navigation, page, post, project, siteSettings',
    )
  })

  it('renders a full Post interface + filter + zod export', () => {
    expect(out).toContain('export interface Post {')
    expect(out).toContain('export type PostField =')
    expect(out).toContain('export type PostFilter =')
    expect(out).toContain('export const PostInputSchema = z.object')
  })

  it('DocumentMap includes all 8 schema names', () => {
    for (const name of [
      'author',
      'category',
      'colors',
      'navigation',
      'page',
      'post',
      'project',
      'siteSettings',
    ]) {
      expect(out).toContain(`"${name}":`)
    }
  })

  it('contains the __run_barkpark_codegen_first__ sentinel', () => {
    expect(out).toContain('__run_barkpark_codegen_first__')
  })

  it('ends with exactly one trailing newline', () => {
    expect(out.endsWith('\n')).toBe(true)
    expect(out.endsWith('\n\n')).toBe(false)
  })

  it('structurally matches the Spike B golden per-schema blocks', () => {
    const golden = readFileSync(GOLDEN_PATH, 'utf8')

    const goldenIfaces = extractInterfaces(golden)
    const outIfaces = extractInterfaces(out)
    expect(goldenIfaces.size).toBeGreaterThan(0)
    for (const [name, body] of goldenIfaces) {
      expect(outIfaces.get(name), `interface ${name} missing from emit`).toBe(body)
    }

    const goldenUnions = extractFieldUnions(golden)
    const outUnions = extractFieldUnions(out)
    for (const [name, body] of goldenUnions) {
      expect(outUnions.get(name), `${name} mismatch`).toBe(body)
    }

    const goldenFilters = extractFilters(golden)
    const outFilters = extractFilters(out)
    for (const [name, body] of goldenFilters) {
      expect(outFilters.get(name), `${name} body mismatch`).toBe(body)
    }
  })
})

describe('emit — loose mode', () => {
  it('header says mode: loose and unknown types collapse to string', () => {
    const doc: RawSchemaDoc = {
      schemas: [
        {
          name: 'custom',
          fields: [{ name: 'weird', type: 'madeUpType' }],
        },
      ],
    }
    const out = emit(doc, { loose: true, schemaHash: 'Z' })
    expect(out).toContain('// mode: loose')
    // The `weird` field should be `string` in loose mode, not `unknown`.
    expect(out).toMatch(/weird:\s+string;/)
  })
})
