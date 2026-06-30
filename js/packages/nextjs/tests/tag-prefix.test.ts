// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, it, expect } from 'vitest'
import { formatTagPrefix } from '../src/tag-prefix'

// This format is the cache-invalidation contract shared by the write side
// (defineActions), the read side (server), and the webhook revalidate fallback.
// If it drifts, a write/webhook stops invalidating the matching read — so pin it.
describe('formatTagPrefix (shared cache-tag namespace)', () => {
  it('SCOPED when both workspace AND project resolve', () => {
    expect(formatTagPrefix('production', 'acme', 'web')).toBe('bp:ws:acme:p:web:ds:production')
  })

  it('LEGACY flat when no workspace', () => {
    expect(formatTagPrefix('production')).toBe('bp:ds:production')
  })

  it('LEGACY flat when workspace present but project missing', () => {
    expect(formatTagPrefix('production', 'acme')).toBe('bp:ds:production')
  })

  it('LEGACY flat when either slug is the empty string', () => {
    expect(formatTagPrefix('production', '', 'web')).toBe('bp:ds:production')
    expect(formatTagPrefix('production', 'acme', '')).toBe('bp:ds:production')
  })
})
