// STATUS-VOCABULARY MANIFEST PARITY FOR apps/mobile
// (mob-bl-status-manifest-mobile-gate).
//
// WHAT THIS FILE RETIRES. design/status-manifest.json is the SINGLE SOURCE for
// the task status vocabulary. Three surfaces derive from it under a gate and a
// fourth did not: scripts/status-manifest-check.sh byte-checks the CSS tone
// block (Part 1), the Go pdrender inline copy (Part 3) and exactly TWO JS/TS
// twins (Part 5 — `STATUS_ROLES` in js/packages/react and `STATUS_LADDER` in
// web). Its Part 5 loop iterates `((react_path, "STATUS_ROLES"), (web_path,
// "STATUS_LADDER"))` and nothing else, so apps/mobile — which hand-copies the
// WHOLE vocabulary in src/papers/portabledoc/blocks/taskboard.tsx — was absent
// from the drift gate entirely. Its own header said as much: the guard was a
// comment. This file makes it a test.
//
// WHY HERE AND NOT ONLY IN THE SHELL GATE. The shell gate runs from
// doc-gates.yml, whose paths block filters on design/** and scripts/**. A gate
// that lives only there cannot fire on an apps/mobile edit — the exact edit
// that introduces mobile-side drift. Running inside the mobile jest suite is
// what makes a taskboard.tsx edit red. The reverse direction (a manifest edit
// mobile never mirrors) needs `design/status-manifest.json` added to
// .github/workflows/mobile.yml's paths, for precisely the reason that file's
// own header already gives for its three non-mobile paths; that half is filed,
// not silently assumed.
//
// THE ONE RECORDED DIVERGENCE. `progress` is the only role whose glyph is NOT
// byte-equal to the manifest, and it is a RULING, not an oversight — see
// PROGRESS_GLYPH_RULING below. The ruling is asserted to be EXHAUSTIVE, so a
// second divergence cannot hide behind the first.
//
// MUTATION-VALIDITY (both directions, proven at authoring time):
//   1. change ROLE_GLYPH.done from '✓' to '✔' in taskboard.tsx → the glyph
//      case reds naming `done`; restore → green.
//   2. add a role to design/status-manifest.json's roles array → the role-set
//      and BOARD_ROLES-order cases red; restore → green.
//   3. drop `researching` from BOARD_ROLES → the lane-order case reds.
//   4. widen PROGRESS_GLYPH_RULING to a second role → the exhaustiveness case
//      reds, because that role's glyph does in fact match.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

import {
  BOARD_ROLES,
  ROLE_GLYPH,
  ROLE_LABEL,
  STATUS_TO_ROLE,
  glyphOf,
  labelOf,
  roleOf,
} from '../src/papers/portabledoc/blocks/taskboard'

// taskboard.tsx sits in the blocks tree whose siblings reach react-native-webview
// at import time; the TurboModule throws under jest-expo unless mocked (the
// standing precedent in this suite).
jest.mock('react-native-webview', () => ({ WebView: () => null }))

interface ManifestRole {
  role: string
  glyph: string
  spinner: boolean
  label: string
  meaning: string
}
interface StatusManifest {
  statuses: Record<string, string>
  default_role: string
  roles: ManifestRole[]
}

// Read off disk, from the repo root — the SAME artifact the shell gate reads,
// never a copy. __dirname is apps/mobile/__tests__.
const MANIFEST_PATH = join(__dirname, '..', '..', '..', 'design', 'status-manifest.json')
const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8')) as StatusManifest

const manifestOrder = manifest.roles.map((r) => r.role)
const manifestByRole = new Map(manifest.roles.map((r) => [r.role, r]))

/** The JS-only fail-open sentinel (charter D11). It is NEVER a lifecycle state,
 * so it is the ONE sanctioned non-manifest role — the same allowance the shell
 * gate's SANCTIONED_EXTRA makes for the react and web twins. */
const SENTINEL = 'unknown'

/** `cancel` resolves and renders, but it is not a BOARD LANE: the web folds
 * cancelled rows into a tally rather than giving them a column, and mobile
 * mirrors that. Recorded here so the lane-order assertion below stays a byte
 * check against the manifest rather than a hand-kept second list. */
const NON_LANE_ROLES: ReadonlySet<string> = new Set(['cancel'])

/** THE ONE GLYPH RULING. The manifest gives `progress` an EMPTY glyph with
 * spinner:true — the web paints an empty span whose ::before CSS-animates the
 * Braille frames. A mobile block renderer is pure by charter D50 (no hooks), so
 * there is no animation to run and an empty glyph would render as a blank cell.
 * Mobile ships '◐', the glyph it already uses for in_progress in chat.tsx, so
 * the app stays internally consistent instead of importing the web's
 * reduced-motion fallback frame. This map is the recorded decision AND its
 * expected value: a change to either side reds. */
const PROGRESS_GLYPH_RULING: Readonly<Record<string, string>> = { progress: '◐' }

/** Manifest labels are lowercase prose ("in progress"); mobile renders them as
 * a column heading and sentence-cases the first character ("In progress"). That
 * is a MECHANICAL relation, not a licence to diverge — asserting the relation
 * still catches "In Progress", a renamed label, or a dropped role. */
function sentenceCase(s: string): string {
  return s.length === 0 ? s : s[0]!.toUpperCase() + s.slice(1)
}

describe('mobile status vocabulary ≡ design/status-manifest.json', () => {
  it('reads a manifest with the shape this file assumes', () => {
    expect(manifest.roles.length).toBeGreaterThan(0)
    expect(Object.keys(manifest.statuses).length).toBeGreaterThan(0)
    expect(typeof manifest.default_role).toBe('string')
  })

  it('resolves EVERY manifest status — aliases and terminal states included — to its manifest role', () => {
    for (const [status, role] of Object.entries(manifest.statuses)) {
      expect(roleOf(status)).toBe(role)
      expect(STATUS_TO_ROLE[status]).toBe(role)
    }
  })

  it('maps exactly the manifest statuses — no hand-added status key', () => {
    expect(Object.keys(STATUS_TO_ROLE).sort()).toEqual(Object.keys(manifest.statuses).sort())
  })

  it('falls back to default_role for an absent or empty status', () => {
    expect(roleOf('')).toBe(manifest.default_role)
    expect(roleOf(undefined)).toBe(manifest.default_role)
    expect(roleOf(null)).toBe(manifest.default_role)
  })

  it('fails OPEN to the sentinel for an unrecognized status, never to default_role', () => {
    expect(roleOf('not-a-status')).toBe(SENTINEL)
    expect(SENTINEL).not.toBe(manifest.default_role)
    expect(glyphOf(SENTINEL)).toBe(ROLE_GLYPH[SENTINEL])
    expect(labelOf(SENTINEL)).toBe(ROLE_LABEL[SENTINEL])
  })

  it('carries the manifest role set plus the ONE sanctioned sentinel, in both tables', () => {
    const want = [...manifestOrder, SENTINEL].sort()
    expect(Object.keys(ROLE_GLYPH).sort()).toEqual(want)
    expect(Object.keys(ROLE_LABEL).sort()).toEqual(want)
  })

  it('byte-matches the manifest glyph for every role outside the recorded ruling', () => {
    for (const role of manifestOrder) {
      if (role in PROGRESS_GLYPH_RULING) continue
      expect([role, ROLE_GLYPH[role]]).toEqual([role, manifestByRole.get(role)!.glyph])
    }
  })

  it('holds the recorded glyph ruling to its recorded value', () => {
    for (const [role, glyph] of Object.entries(PROGRESS_GLYPH_RULING)) {
      expect(manifestByRole.has(role)).toBe(true)
      expect(ROLE_GLYPH[role]).toBe(glyph)
    }
  })

  it('keeps the ruling EXHAUSTIVE — every ruled role genuinely diverges from the manifest', () => {
    // Without this, widening the ruling would silently exempt a role that could
    // have conformed. A ruling row that no longer earns its exemption reds.
    for (const role of Object.keys(PROGRESS_GLYPH_RULING)) {
      expect(ROLE_GLYPH[role]).not.toBe(manifestByRole.get(role)!.glyph)
    }
    // And the divergence is exactly the ruled set — nothing else drifts.
    const diverging = manifestOrder.filter((r) => ROLE_GLYPH[r] !== manifestByRole.get(r)!.glyph)
    expect(diverging.sort()).toEqual(Object.keys(PROGRESS_GLYPH_RULING).sort())
  })

  it('sentence-cases the manifest label for every role, byte for byte', () => {
    for (const role of manifestOrder) {
      const want = sentenceCase(manifestByRole.get(role)!.label)
      expect([role, ROLE_LABEL[role]]).toEqual([role, want])
    }
  })

  it('orders the board lanes by manifest order, minus the recorded non-lane roles', () => {
    const want = manifestOrder.filter((r) => !NON_LANE_ROLES.has(r))
    expect([...BOARD_ROLES]).toEqual(want)
  })

  it('keeps NON_LANE_ROLES honest — every excluded role is a real manifest role', () => {
    for (const role of NON_LANE_ROLES) expect(manifestByRole.has(role)).toBe(true)
    expect(BOARD_ROLES).not.toContain(SENTINEL)
  })

  it('gives the sentinel a glyph and a label distinct from every manifest role', () => {
    // Fail-open must never masquerade as a real state (D11).
    expect(manifestOrder).not.toContain(SENTINEL)
    for (const role of manifestOrder) {
      expect(ROLE_GLYPH[SENTINEL]).not.toBe(ROLE_GLYPH[role])
    }
  })
})
