import { describe, it, expect } from 'vitest'
import { defineConfig } from '../src/index'
import type { BarkparkCodegenConfig, BarkparkSchemaJson } from '../src/index'

describe('@barkpark/codegen scaffold', () => {
  it('defineConfig returns its input', () => {
    const cfg: BarkparkCodegenConfig = {
      dataset: 'production',
      apiUrl: 'https://api.barkpark.cloud',
      output: './barkpark.types.ts',
    }
    expect(defineConfig(cfg)).toBe(cfg)
  })
  it('types are reachable', () => {
    const s: BarkparkSchemaJson = { _schemaVersion: 1, datasetSchemaHash: 'abc', schemas: [] }
    expect(Array.isArray(s.schemas)).toBe(true)
  })
})
