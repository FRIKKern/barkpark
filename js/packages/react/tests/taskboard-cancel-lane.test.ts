// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE CANCEL LANE (task-881952f8d8417f4b). A cancelled row renders in its OWN
// lane, LAST and de-emphasised, carrying the manifest's ✕ — never dropped, never
// homed in `open`.
//
// WHAT THIS SURFACE DID BEFORE: it HOMED cancelled rows in `open`. BOARD_ROLES
// was a hand-typed seven-role list without `cancel`, so `BOARD_ROLES.includes(role)
// ? role : 'open'` filed every cancelled row into the CLAIMABLE lane — the one
// `bp task ready` serves and agents read as work available to take. That is not
// the safe fallback it looks like: it manufactures phantom ready work on a surface
// people act from.
//
// FAIL-BEFORE (c1): with src/blocks/taskboard.ts reverted to origin/main, the
// first case reds — `expected '<div class="bp-board">…' to contain
// 'bp-board__col--cancel'` — because the cancelled card renders inside
// `bp-board__col--open` instead.
//
// The expectations here are COMPUTED from design/status-manifest.json, never
// retyped: written as a literal they would be a second copy of the lane list and
// could not catch the class of bug they exist for.
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, it, expect } from 'vitest'
import { renderPortableDocument, type Block } from '../src'

interface ManifestRole {
  role: string
  glyph: string
  label: string
}
interface StatusManifest {
  statuses: Record<string, string>
  roles: ManifestRole[]
}

const MANIFEST_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', '..',
  'design',
  'status-manifest.json',
)
const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8')) as StatusManifest
const CANCEL = 'cancel'
const manifestRoles = manifest.roles.map((r) => r.role)
/** The lane order the ruling defines: every manifest rung, terminal `cancel` last. */
const wantLanes = [...manifestRoles.filter((r) => r !== CANCEL), CANCEL]
/** One stored status per role, off the manifest's own statuses map (`progress` is
 * a role, `in_progress` is the status — assuming they are the same string is how a
 * board test quietly stops driving the real roleOf seam). */
const statusFor = (role: string): string =>
  Object.entries(manifest.statuses).find(([, r]) => r === role)![0]

const board = (rows: Array<Record<string, unknown>>): string =>
  renderPortableDocument([{ type: 'task-board', snapshot: rows } as unknown as Block])

describe('task-board cancel lane', () => {
  it('renders a cancelled row in its own lane, LAST, with the manifest ✕', () => {
    const html = board([
      { title: 'Claim me', status: 'ready' },
      { title: 'Abandoned spike', status: 'cancelled' },
      { title: 'Shipped', status: 'done' },
    ])

    // NEVER DROPPED, and in a lane of its own.
    expect(html).toContain('bp-board__col--cancel')
    expect(html).toContain('<span class="bp-board__label">Cancelled</span>')
    expect(html).toContain('Abandoned spike')

    // The manifest's glyph, through the shared seam — not a hand-typed mark.
    expect(html).toContain(manifest.roles.find((r) => r.role === CANCEL)!.glyph)

    // NEVER HOMED IN `open`: no open row in the snapshot, so an open lane
    // appearing at all IS the misfile this surface used to ship.
    expect(html).not.toContain('bp-board__col--open')

    // LAST: the cancel lane trails every live lane.
    const cancelAt = html.indexOf('bp-board__col--cancel')
    for (const live of ['bp-board__col--ready', 'bp-board__col--done']) {
      const at = html.indexOf(live)
      expect(at, `${live} must render before the cancel lane`).toBeGreaterThan(-1)
      expect(at, `${live} renders AFTER the cancel lane — cancel must be LAST`).toBeLessThan(cancelAt)
    }
  })

  it('keeps the open lane claimable — no terminal or thought state falls into it', () => {
    const html = board(manifestRoles.map((role) => ({ title: `row-${role}`, status: statusFor(role) })))

    // Slice the open lane: from its class to the start of the next lane.
    const openAt = html.indexOf('bp-board__col--open')
    expect(openAt, 'expected an open lane').toBeGreaterThan(-1)
    const rest = html.slice(openAt)
    const nextAt = rest.indexOf('<div class="bp-board__col ', 1)
    const openLane = nextAt === -1 ? rest : rest.slice(0, nextAt)

    // PRECONDITION: the slice really is the open lane. Without it the loop below
    // could pass on an empty string and measure nothing.
    expect(openLane).toContain('row-open')

    for (const role of manifestRoles.filter((r) => r !== 'open')) {
      expect(
        openLane,
        `a ${role} row landed in the CLAIMABLE open lane — \`bp task ready\` serves it`,
      ).not.toContain(`row-${role}`)
    }
  })

  it('gives EVERY manifest rung a lane, in manifest order with cancel last — derived, not retyped', () => {
    const html = board(manifestRoles.map((role) => ({ title: `row-${role}`, status: statusFor(role) })))

    // The rendered lane order, read back off the markup.
    const got = [...html.matchAll(/bp-board__col--([a-z]+)/g)].map((m) => m[1])
    expect(got).toEqual(wantLanes)

    // MUTATION (c3): retype BOARD_ROLES beside the manifest as the seven-role
    // literal and this reds on the missing `cancel` lane; drop any other rung and
    // it reds naming that one. A future manifest rung joins the board for free.
    for (const role of manifestRoles) {
      expect(got, `manifest rung "${role}" has NO lane — its rows are silently dropped`).toContain(role)
    }
    expect(got[got.length - 1]).toBe(CANCEL)
  })
})

/* ── the off-ladder fallback (task-1618e7d0b0d96fb6) ────────────────────────── */
//
// Giving `cancel` its own lane (PR #17985) removed the last LIFECYCLE status that
// could reach `BOARD_ROLES.includes(role) ? role : 'open'`, so the fallback's own
// behaviour — "a status the ladder does not know still renders, and homes in the
// open lane" — went unmeasured on every surface at once. Go covers it
// (TestTaskBoardOffLadderStatusHomesInOpen, internal/pdrender/taskblocks_test.go);
// this is the react arm.
//
// The subject is DERIVED, never typed: a literal off-ladder status would go
// vacuous the day the manifest adopts that word, and the arm would keep passing
// while measuring a known rung. `offLadderStatus` is grown until the manifest's
// own statuses map disowns it, so it is off-ladder BY CONSTRUCTION.
//
// The preconditions are deliberately NOT lane-existence checks. A lane-existence
// precondition is destroyed by exactly the mutations these arms exist to catch
// (drop the row -> no open lane; widen the fallback -> no ready lane), so it
// would fire FIRST and the board-level assertion would never be reached. Both
// preconditions below survive both mutations; the assertion that reds is the one
// about the board.

/** A status the ladder does not know — a predicate, not a pinned word. */
const offLadderStatus = (() => {
  let s = 'off-ladder'
  while (s in manifest.statuses) s += '-x'
  return s
})()

/** The markup of one board lane: from its class to the start of the next lane.
 * `''` when that lane did not render — a containment assertion against it then
 * reports the ROW that is missing, not a null slice. */
function laneSlice(html: string, role: string): string {
  const at = html.indexOf(`bp-board__col--${role}`)
  if (at === -1) return ''
  const rest = html.slice(at)
  const next = rest.indexOf('<div class="bp-board__col ', 1)
  return next === -1 ? rest : rest.slice(0, next)
}

describe('task-board off-ladder fallback', () => {
  it('renders an off-ladder status VISIBLE, in the open lane — and widens no further', () => {
    // PRECONDITION 1: the subject really is off the ladder. Without it the whole
    // case could be measuring a known rung and still pass.
    expect(
      Object.keys(manifest.statuses),
      `"${offLadderStatus}" is a MANIFEST status — this arm would measure a known rung`,
    ).not.toContain(offLadderStatus)

    const html = board([
      { title: 'row-ready', status: statusFor('ready') },
      { title: 'row-offladder', status: offLadderStatus },
      { title: 'row-cancelled', status: statusFor(CANCEL) },
    ])

    // PRECONDITION 2: a board rendered with lanes at all. Nothing-measured and
    // all-clear look identical against an empty string.
    expect(html, 'no board rendered — the arms below would measure nothing').toContain(
      'bp-board__col--',
    )

    // LOUD: never dropped, and homed in `open`.
    expect(html, 'the off-ladder row VANISHED from the board').toContain('row-offladder')
    expect(
      laneSlice(html, 'open'),
      'the off-ladder row did not home in the open lane — the fail-open fallback is gone',
    ).toContain('row-offladder')

    // QUIET: the fallback did NOT widen. Every KNOWN rung keeps its own lane, so
    // `open` gained exactly the one unknown row and nothing else.
    const openLane = laneSlice(html, 'open')
    expect(openLane, 'a READY row was swept into the fallback — the fallback widened').not.toContain(
      'row-ready',
    )
    expect(
      openLane,
      'a CANCELLED row was swept into the fallback — phantom claimable work',
    ).not.toContain('row-cancelled')
    expect(laneSlice(html, 'ready'), 'the ready row left its own lane').toContain('row-ready')
    expect(laneSlice(html, CANCEL), 'the cancelled row left its own lane').toContain('row-cancelled')
  })

  it('paints the off-ladder row with the dim `unknown` glyph, not the open circle', () => {
    // The LANE is `open`; the GLYPH is the row's own resolved role (boardCol reads
    // roleOf per row). Both halves matter: homing it in open must not disguise it
    // as a real open rung.
    const html = board([{ title: 'row-offladder', status: offLadderStatus }])
    const openGlyph = manifest.roles.find((r) => r.role === 'open')!.glyph

    expect(html, 'the off-ladder row VANISHED from the board').toContain('row-offladder')
    expect(
      html,
      'the off-ladder row paints the OPEN glyph — it reads as real, claimable backlog',
    ).not.toContain(`>${openGlyph}<`)
  })
})
