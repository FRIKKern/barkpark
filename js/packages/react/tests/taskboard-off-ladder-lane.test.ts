// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE FAIL-OPEN HALF of the cancel-lane ruling (task-f2747c0f7bfe1735, residual
// of task-881952f8d8417f4b) — the react leg. The Go leg is
// TestTaskBoardOffLadderStatusHomesInOpen in internal/pdrender/taskblocks_test.go.
//
// WHY THIS ARM HAD TO BE CUT. Giving `cancel` a lane of its own fixed the DROP,
// but it also removed the last LIFECYCLE status that could ever reach the board's
// lane fallback (`BOARD_ROLES.includes(role) ? role : 'open'`). taskboard.ts says
// so in as many words: "the ONLY role the fallback can still catch is the
// non-manifest `unknown` sentinel". Every board arm that exists asserts where a
// KNOWN status lands, so after the cancel lane shipped, the fallback itself went
// UNMEASURED on this surface — a comment claiming a behaviour with no test under
// it. This file is that test.
//
// THE RULE. A status the manifest does not carry must still be SHOWN, in the
// `open` lane, wearing the JS-only dim `unknown` glyph (decision 11) rather than
// open's bright circle. Two seams, not one: roleOf maps the off-ladder status to
// the `unknown` sentinel, and the board fallback homes that column-less role in
// `open`. Vanishing is the WORSE failure — a reader cannot tell "no such work"
// from "this surface will not draw it" — and that is exactly the defect the
// cancel lane was cut to end.
//
// TWO ARMS, both driven through renderPortableDocument (the public seam):
//   - LOUD: the off-ladder row is VISIBLE, in the open lane, with the dim glyph.
//     Dropping the fallback (`const col = role`) makes the row vanish — no lane
//     ever collects `unknown` — and this reds.
//   - QUIET: the fallback did NOT widen. The known rows in the same snapshot keep
//     their own lanes: `ready` in Ready, `cancelled` in Cancelled. A "fix" that
//     swept every row into `open` would still pass the loud arm; it reds here.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, it, expect } from 'vitest'
import { renderPortableDocument, type Block } from '../src'
import { roleOf } from '../src/inline'

interface StatusManifest {
  statuses: Record<string, string>
  roles: Array<{ role: string; glyph: string; label: string }>
}
const manifest = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..', 'design', 'status-manifest.json'),
    'utf8',
  ),
) as StatusManifest

/** A status no manifest rung claims. */
const OFF_LADDER = 'not-a-status'

const board = (rows: Array<Record<string, unknown>>): string =>
  renderPortableDocument([{ type: 'task-board', snapshot: rows } as unknown as Block])

/** The lane slice for `role`: from its column class to the start of the next column. */
function lane(html: string, role: string): string {
  const at = html.indexOf(`bp-board__col--${role}`)
  expect(at, `expected a ${role} lane in the rendered board`).toBeGreaterThan(-1)
  const rest = html.slice(at)
  const next = rest.indexOf('<div class="bp-board__col ', 1)
  return next === -1 ? rest : rest.slice(0, next)
}

describe('task-board off-ladder status', () => {
  // PRECONDITION, asserted not assumed: the status really is off the ladder, and
  // the surface really does fail open. Without these the arms below could quietly
  // become assertions about a rung the manifest DOES carry (and then measure
  // nothing about the fallback at all).
  it('PRECONDITION: the status is off the manifest ladder and resolves to the sentinel', () => {
    expect(Object.keys(manifest.statuses)).not.toContain(OFF_LADDER)
    expect(manifest.roles.map((r) => r.role)).not.toContain('unknown')
    expect(roleOf(OFF_LADDER)).toBe('unknown')
  })

  it('LOUD: an off-ladder row is SHOWN, in the open lane, with the dim sentinel glyph', () => {
    const html = board([
      { title: 'row-ready', status: 'ready' },
      { title: 'row-off', status: OFF_LADDER },
      { title: 'row-cancel', status: 'cancelled' },
    ])

    // NEVER DROPPED. This is the assertion the whole file exists for.
    expect(html, 'an off-ladder row VANISHED from the board').toContain('row-off')

    // And it homes in `open` — the manifest default_role, reached through the
    // board's column fallback.
    expect(lane(html, 'open')).toContain('row-off')

    // Wearing the sentinel glyph, not open's bright circle: the board must not
    // dress an unrecognized status up as real open work.
    expect(lane(html, 'open')).toContain('bp-g--unknown')
  })

  it('QUIET: the fallback did not widen — known rows keep their own lanes', () => {
    const html = board([
      { title: 'row-ready', status: 'ready' },
      { title: 'row-off', status: OFF_LADDER },
      { title: 'row-cancel', status: 'cancelled' },
    ])

    // Each known row in ITS lane...
    expect(lane(html, 'ready')).toContain('row-ready')
    expect(lane(html, 'cancel')).toContain('row-cancel')

    // ...and NOT swept into the claimable open lane alongside the off-ladder row.
    // `bp task ready` serves `open`; a cancelled or ready row landing there is
    // phantom work on a surface people act from.
    const open = lane(html, 'open')
    expect(open, 'a ready row was swept into the open lane — the fallback widened').not.toContain('row-ready')
    expect(open, 'a cancelled row was swept into the open lane — the fallback widened').not.toContain('row-cancel')
    expect(open).toContain('<span class="bp-board__count">1</span>')
  })
})
