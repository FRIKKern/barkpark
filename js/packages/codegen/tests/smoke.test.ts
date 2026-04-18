import { describe, it, expect } from 'vitest'
import { defineConfig } from '../src/index'
import type { BarkparkCodegenConfig, BarkparkSchemaJson } from '../src/index'

describe('@barkpark/codegen scaffold', () => {
  it('defineConfig returns its input', () => {
    const cfg: BarkparkCodegenConfig = { input: './schema.json', output: './out.ts' }
    expect(defineConfig(cfg)).toBe(cfg)
  })
  it('types are reachable', () => {
    const s: BarkparkSchemaJson = { types: [] }
    expect(Array.isArray(s.types)).toBe(true)
  })
})
