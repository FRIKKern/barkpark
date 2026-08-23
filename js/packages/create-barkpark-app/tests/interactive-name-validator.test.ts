// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { interactiveNameError, normalizeProjectName } from '../src/prompts.js'

/**
 * cca-backlog-interactive-name-validator: the interactive validator checked
 * the RAW entered string while runPrompts normalises at return — so `foo/..`
 * passed validation, normalised to `..`, and targetDir resolved to the PARENT
 * of cwd. The validator now validates the NORMALISED name via the same
 * projectNameError the non-interactive path uses (one owner for the rule).
 */
describe('interactive name validator validates the NORMALISED name', () => {
  it('rejects foo/.. — the raw-value check let it through as ".."', () => {
    // The exact escape: raw 'foo/..' is non-empty and not dot-leading, but
    // normalises to '..'. The validator must judge the normalised form.
    expect(normalizeProjectName('foo/..')).toBe('..')
    expect(interactiveNameError('foo/..')).toMatch(/may not start with "\."/)
  })

  it('rejects the other normalise-to-hidden shapes the same way', () => {
    expect(interactiveNameError('foo/.git')).toMatch(/may not start with "\."/)
    expect(interactiveNameError('.')).toMatch(/may not start with "\."/)
    expect(interactiveNameError('   ')).toMatch(/non-empty directory name/)
  })

  it('accepts a normal name, and a path whose basename is a normal name', () => {
    expect(interactiveNameError('my-barkpark-site')).toBeUndefined()
    expect(interactiveNameError('apps/my-site')).toBeUndefined()
  })
})
