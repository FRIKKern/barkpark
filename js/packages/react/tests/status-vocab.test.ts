// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Status-vocabulary contract (task-lifecycle-visibility, charter D11/D13): the
// two thought states resolve to their own dim roles, an UNRECOGNIZED non-empty
// status fails OPEN to a dim-neutral `unknown` role (never masquerading as the
// bright `open` circle), an ABSENT/empty status still defaults to `open`, and the
// legend key stays byte-frozen to the 8 canonical manifest roles.

import { describe, it, expect } from 'vitest'
import {
  roleOf,
  glyphChar,
  glyphHtml,
  labelForRole,
  LEGEND_ROLES,
  STATUS_ROLES,
} from '../src/inline'

describe('status vocabulary — thought states + fail-open', () => {
  it('considering/researching resolve to their OWN roles with the correct glyphs', () => {
    expect(roleOf('considering')).toBe('considering')
    expect(roleOf('researching')).toBe('researching')
    expect(glyphChar('considering')).toBe('◌') // U+25CC dotted circle
    expect(glyphChar('researching')).toBe('◎') // U+25CE bullseye
    expect(labelForRole('considering')).toBe('considering')
    expect(labelForRole('researching')).toBe('researching')
  })

  it('an UNRECOGNIZED non-empty status fails open to the dim-neutral unknown role', () => {
    expect(roleOf('banana')).toBe('unknown')
    expect(roleOf('some_future_state')).toBe('unknown')
    // The unknown role is NEVER the bright open circle — its own dim glyph.
    expect(glyphChar('unknown')).toBe('◦') // U+25E6 white bullet
    expect(glyphChar('unknown')).not.toBe('○') // not open's ring
    // and it renders a static glyph span, not a spinner.
    expect(glyphHtml('unknown')).toBe('<span class="bp-g bp-g--unknown">◦</span>')
  })

  it('ABSENT / empty status keeps the open default (nothing about blank rows changes)', () => {
    expect(roleOf('')).toBe('open')
    expect(roleOf(undefined)).toBe('open')
    expect(roleOf(null)).toBe('open')
    expect(roleOf({})).toBe('open') // non-scalar coerces to '' → open
    // A finite number stringifies (str(42) === '42'), so it is a NON-EMPTY
    // unrecognized status and honestly fails open to unknown — not to open.
    expect(roleOf(42)).toBe('unknown')
  })

  it('known lifecycle statuses are unchanged (no regression)', () => {
    expect(roleOf('open')).toBe('open')
    expect(roleOf('ready')).toBe('ready')
    expect(roleOf('in_progress')).toBe('progress')
    expect(roleOf('blocked')).toBe('blocked')
    expect(roleOf('done')).toBe('done')
    expect(roleOf('closed')).toBe('done')
    expect(roleOf('cancelled')).toBe('cancel')
  })

  it('the legend key stays scoped to the 8 canonical manifest roles', () => {
    // The full role table carries the thought states + the unknown sentinel;
    // the legend (cross-surface parity key) carries the manifest's eight —
    // the JS-only `unknown` sentinel is never a legend row.
    expect(STATUS_ROLES.map((r) => r.role)).toEqual([
      'open',
      'ready',
      'progress',
      'blocked',
      'done',
      'cancel',
      'considering',
      'researching',
      'unknown',
    ])
    expect(LEGEND_ROLES.map((r) => r.role)).toEqual([
      'open',
      'ready',
      'progress',
      'blocked',
      'done',
      'cancel',
      'considering',
      'researching',
    ])
  })
})
