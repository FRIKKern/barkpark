// STATUS-VOCABULARY MANIFEST PARITY FOR apps/mobile
// (mob-bl-status-manifest-mobile-gate).
//
// WHAT THIS FILE RETIRES. design/status-manifest.json is the SINGLE SOURCE for
// the task status vocabulary. Three surfaces derived from it under a gate and a
// fourth did not: scripts/status-manifest-check.sh byte-checks the CSS tone
// block (Part 1), the Go pdrender inline copy (Part 3) and TWO JS/TS twins
// (Part 5 — `STATUS_ROLES` in js/packages/react and `STATUS_LADDER` in web).
// apps/mobile hand-copies the WHOLE vocabulary in
// src/papers/portabledoc/blocks/taskboard.tsx and appeared nowhere in that
// script; the file's own header said the guard was a comment.
//
// THE TWO GATES, AND WHY BOTH. This file is one of a PAIR, and the pair is the
// point — each half fires on the edit the other cannot see:
//   • THIS test runs inside the mobile jest suite, which .github/workflows/
//     mobile.yml triggers on apps/mobile/**. So an edit to taskboard.tsx —
//     the edit that introduces MOBILE-side drift — reds here.
//   • scripts/status-manifest-check.sh Part 5b byte-checks the same file from
//     doc-gates.yml, whose paths block carries design/status-manifest.json by
//     name. So a MANIFEST edit mobile never mirrors reds there — the direction
//     mobile.yml cannot see, because it does not trigger on design/**.
// That job's paths block also carries `**/*.tsx`, so a taskboard.tsx edit runs
// the shell gate too; both surfaces are watched from both sides, and NO
// workflow change was needed to get there — a claim worth checking rather than
// assuming, because an added path that a glob already covers is noise, and a
// gate whose job never runs is a decoration.
// Neither half alone is a gate: a checker whose job never runs on the edit it
// exists to catch is a decoration, and shipping one is worse than shipping none.
//
// THE ADJUDICATED DIVERGENCE lives in the MANIFEST, not here — `progress`, in
// `platform_overrides`, with its reason. This file reads it rather than
// restating it, so there is one source and not two places to drift. See the
// OVERRIDES block below for what keeps it honest.
//
// MUTATION-VALIDITY (both directions, proven at authoring time):
//   1. change ROLE_GLYPH.done from '✓' to '✔' in taskboard.tsx → the glyph
//      case reds naming `done`; restore → green.
//   2. add a role to design/status-manifest.json's roles array → the role-set
//      and BOARD_ROLES-order cases red; restore → green.
//   3. drop `researching` from BOARD_ROLES → the lane-order case reds.
//   4. delete the `progress` row from platform_overrides → the glyph case reds,
//      because mobile's ◐ is then unexplained drift.
//   5. add a second role to platform_overrides whose glyph does NOT differ →
//      the exhaustiveness case reds.
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
interface PlatformOverride {
  glyph: string
  reason: string
}
interface StatusManifest {
  statuses: Record<string, string>
  default_role: string
  roles: ManifestRole[]
  /** Adjudicated per-surface divergences, keyed by surface then role. */
  platform_overrides?: Record<string, Record<string, PlatformOverride>>
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

/** THE ADJUDICATED DIVERGENCES, READ FROM THE MANIFEST — not restated here.
 *
 * `progress` is the one role whose glyph is legitimately not byte-equal: the
 * manifest gives it an EMPTY glyph with spinner:true (the web paints an empty
 * span whose ::before CSS-animates the Braille frames), and a mobile block
 * renderer is pure by charter D50, so there is no animation to run and an empty
 * glyph would paint a blank cell. Mobile ships the glyph it already uses for
 * in_progress in chat.tsx. Mobile CONFORMING would be the regression.
 *
 * That ruling and its reason live in design/status-manifest.json's
 * `platform_overrides`, so this file and scripts/status-manifest-check.sh read
 * ONE source instead of each carrying a copy — a hardcoded exception here would
 * be a second place to update and therefore a second place to drift. The cases
 * below hold the override honest in both directions: it must name a real role,
 * it must ACTUALLY differ, it must carry a reason, and the set of roles that
 * diverge must EQUAL the set declared, so a second divergence can never hide
 * behind the sanctioned one. */
const OVERRIDES: Readonly<Record<string, PlatformOverride>> = Object.fromEntries(
  Object.entries(manifest.platform_overrides?.['apps/mobile'] ?? {}).filter(
    ([role]) => !role.startsWith('$'),
  ),
)

/** The glyph mobile must ship for a role: the manifest's, unless the manifest
 * itself records an override for this surface. */
function wantGlyph(role: string): string {
  return OVERRIDES[role]?.glyph ?? manifestByRole.get(role)!.glyph
}

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

  it('ships the glyph the manifest calls for on every role — its own, or its recorded override', () => {
    for (const role of manifestOrder) {
      expect([role, ROLE_GLYPH[role]]).toEqual([role, wantGlyph(role)])
    }
  })

  it('holds every recorded override to a real role, a real value and a stated reason', () => {
    expect(Object.keys(OVERRIDES).length).toBeGreaterThan(0)
    for (const [role, ov] of Object.entries(OVERRIDES)) {
      expect(manifestByRole.has(role)).toBe(true)
      expect(ROLE_GLYPH[role]).toBe(ov.glyph)
      // A ruling without a reason is a skip wearing a ruling's clothes.
      expect((ov.reason ?? '').trim().length).toBeGreaterThanOrEqual(40)
    }
  })

  it('keeps the overrides EXHAUSTIVE — every ruled role genuinely diverges, and nothing else does', () => {
    // Without this, widening the override map would silently exempt a role that
    // could have conformed. An override that no longer earns its keep reds.
    for (const role of Object.keys(OVERRIDES)) {
      expect(ROLE_GLYPH[role]).not.toBe(manifestByRole.get(role)!.glyph)
    }
    // And the divergence is exactly the declared set — nothing else drifts.
    const diverging = manifestOrder.filter((r) => ROLE_GLYPH[r] !== manifestByRole.get(r)!.glyph)
    expect(diverging.sort()).toEqual(Object.keys(OVERRIDES).sort())
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
