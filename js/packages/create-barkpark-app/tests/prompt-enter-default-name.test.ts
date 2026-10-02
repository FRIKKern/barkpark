// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { promptNameValidator } from '../src/prompts.js'

/**
 * Stranger walk (2026-09-30): at "Project name?" the prompt shows
 * `my-barkpark-site`, and pressing Enter answered `Invalid project name "" —
 * provide a non-empty directory name.` @clack/core runs `validate` on the raw
 * value BEFORE its finalize step substitutes `defaultValue`, so the validator
 * must let an empty entry through (clack then fills in the default) while
 * still judging everything the user actually typed.
 */
describe('the name prompt accepts Enter as "take the default"', () => {
  it('passes an empty entry so clack can substitute defaultValue', () => {
    expect(promptNameValidator('')).toBeUndefined()
    expect(promptNameValidator(undefined)).toBeUndefined()
  })

  it('still rejects what the user actually typed when it is invalid', () => {
    expect(promptNameValidator('   ')).toMatch(/non-empty directory name/)
    expect(promptNameValidator('foo/..')).toMatch(/may not start with "\."/)
  })

  it('accepts a normal typed name', () => {
    expect(promptNameValidator('my-site')).toBeUndefined()
  })
})
