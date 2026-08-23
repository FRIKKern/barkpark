// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// STATUS-VOCABULARY MANIFEST PARITY (rpu-backlog-role-ladder-drift-guard,
// charter D15): design/status-manifest.json is the SINGLE SOURCE for the task
// status vocabulary, and this file compares the react package's whole mapping
// against it — not just role/glyph/label (scripts/status-manifest-check.sh
// Part 5 already byte-checks those), but the parts Part 5 does NOT see:
//
//   • the STATUS→ROLE mapping including ALIASES and TERMINAL states
//     (`closed`→done, `cancelled`→cancel, `in_progress`→progress) — proven
//     behaviorally through roleOf() for EVERY manifest statuses entry;
//   • the PRESENTATION FALLBACKS — default_role for an absent/empty status,
//     and the JS-only fail-open `unknown` sentinel as the ONE sanctioned
//     non-manifest role;
//   • spinner and meaning on every legend row, in manifest ORDER.
//
// With this file green, every hand-maintained JS status list is compared
// against the one canonical vocabulary: a manifest edit (new role, changed
// alias, changed default) reds here until the JS renderer catches up, and a
// JS-side edit that drifts from the manifest reds immediately.
//
// MUTATION-VALIDITY (both directions):
//   1. remove the `closed: 'done'` alias from STATUS_TO_ROLE in src/inline.tsx
//      → the alias case reds; restore → green.
//   2. add a bogus role to design/status-manifest.json's roles array
//      → the legend-parity case reds; restore → green.

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, it, expect } from 'vitest'
import { roleOf, LEGEND_ROLES, STATUS_ROLES } from '../src/inline'

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

const MANIFEST_PATH = join(
  dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', '..',
  'design',
  'status-manifest.json',
)
const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8')) as StatusManifest

describe('status vocabulary ≡ design/status-manifest.json (the one canonical source)', () => {
  it('every manifest status — aliases and terminal states included — resolves to its manifest role', () => {
    for (const [status, role] of Object.entries(manifest.statuses)) {
      expect(roleOf(status), `roleOf('${status}')`).toBe(role)
    }
    // The terminal aliases the manifest carries today, named so a silent
    // manifest rename cannot leave this suite vacuously green:
    expect(manifest.statuses).toHaveProperty('closed')
    expect(manifest.statuses).toHaveProperty('cancelled')
  })

  it('the legend ladder equals the manifest roles array — order, glyph, spinner, label, meaning', () => {
    expect(
      LEGEND_ROLES.map(({ role, glyph, spinner, label, meaning }) => ({
        role, glyph, spinner, label, meaning,
      })),
    ).toEqual(manifest.roles)
  })

  it('an absent/empty status falls back to the manifest default_role', () => {
    expect(roleOf('')).toBe(manifest.default_role)
    expect(roleOf(undefined)).toBe(manifest.default_role)
  })

  it("the ONLY non-manifest role is the fail-open 'unknown' sentinel", () => {
    const manifestRoles = new Set(manifest.roles.map((r) => r.role))
    const extras = STATUS_ROLES.map((r) => r.role).filter((r) => !manifestRoles.has(r))
    expect(extras).toEqual(['unknown'])
    // …and an unrecognized non-empty status lands on it, never on a bright role.
    expect(roleOf('definitely-not-a-status')).toBe('unknown')
  })
})
