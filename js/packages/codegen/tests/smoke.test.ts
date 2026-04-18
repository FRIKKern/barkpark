import { describe, it, expect } from 'vitest'
import { defineConfig, emit, sha256Canonical } from '../src/index'
import type { BarkparkCodegenConfig, RawSchemaDoc } from '../src/index'

describe('@barkpark/codegen scaffold', () => {
  it('defineConfig returns its input', () => {
    const cfg: BarkparkCodegenConfig = {
      apiUrl: 'http://localhost:4000',
      dataset: 'production',
      codegen: { out: './barkpark.types.ts' },
    }
    expect(defineConfig(cfg)).toBe(cfg)
  })

  it('emit is a function and sha256Canonical hashes consistently', () => {
    expect(typeof emit).toBe('function')
    const a = sha256Canonical({ a: 1, b: 2 })
    const b = sha256Canonical({ b: 2, a: 1 })
    expect(a).toBe(b)
    expect(a).toMatch(/^[0-9a-f]{64}$/)
  })

  it('emit produces a header-stamped, non-empty module for an empty schema doc', () => {
    const doc: RawSchemaDoc = { schemas: [] }
    const out = emit(doc, { loose: false, schemaHash: 'deadbeef' })
    expect(out).toContain('// AUTO-GENERATED')
    expect(out).toContain('// @barkpark-schema-hash: deadbeef')
    expect(out).toContain('// codegen-version: 0.1.0')
    expect(out).toContain('__run_barkpark_codegen_first__')
    expect(out).toContain('export function typedClient')
  })
})
