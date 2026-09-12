// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// ─────────────────────────────────────────────────────────────────────────────
// SDK ↔ capabilities-manifest parity.
//
// THE NAMED FAILURE MODE
//
// `@barkpark/core` promises a typed helper per server capability, but nothing
// tied a helper to the route it dials. Before this file, `git grep -li
// capabilities js/packages` was EMPTY: a `/v1` route could be renamed, split or
// retired server-side and every SDK method that called it would keep compiling,
// keep type-checking, keep passing its own msw-mocked unit test — and 404 in
// production. The mock is the problem: a test that stubs the URL it asserts
// cannot notice that the URL stopped existing.
//
// WHAT THIS FILE COMPARES, AND WHAT IT DELIBERATELY DOES NOT
//
// The manifest is a COMMAND surface (what `bp`/MCP can drive), not an inventory
// of every mounted route, and the SDK owns transport-level helpers that are not
// commands. So a global set-equality check would be false on both ends and
// would be muted within a week. Instead the fixture carries a reviewed
// COVERAGE MAP — one entry per SDK method that promises a manifest-backed route
// — plus an explicit `sdk_only` allow-list with a rationale per entry. Three
// assertions, three different directions:
//
//   1. every `coverage` entry resolves to a route in the manifest snapshot
//      (a covered route that was renamed/removed reds);
//   2. every method on the live client surface is either covered or
//      allow-listed (a new SDK method reds until someone classifies it);
//   3. every `coverage`/`sdk_only` entry names a method that actually exists
//      (an unexplained or stale map entry reds).
//
// Manifest commands with NO SDK method are expected and are NOT a failure — see
// `manifest_only_rationale` in the fixture.
//
// THE FIXTURE, ITS SOURCE TIER, AND HOW TO REFRESH IT
//
//   file   : api/test/support/fixtures/sdk-capabilities-parity.json — read
//            ACROSS the tree, the same way @barkpark/react's PortableDoc
//            parity harnesses read their goldens out of that directory. It
//            does not live under js/ because the Elixir producer-side lock
//            below must read it from inside api/, or
//            scripts/elixir-path-escape-check.sh reds it as an undispatched
//            repo-root read.
//   source : Barkpark.Plugins.Capabilities.manifest("admin", project: false)
//            ["commands"] — tier "admin", UN-PROJECTED. The existence-hiding
//            projection drops commands above the caller's tier, so a lower-tier
//            cut would record a smaller route set and weaken every assertion
//            here without anyone editing an assertion.
//   refresh: cd api && mix run test/support/fixtures/refresh-sdk-capabilities-parity.exs
//            (on macOS prefix `CC=/usr/bin/clang`). The script rewrites ONLY
//            `manifest_routes` + `generated_at`; `coverage` and `sdk_only` are
//            hand-authored review artifacts and are carried through untouched,
//            so refreshing can never be the move that "fixes" a parity red.
//
// WHY A SECOND, ELIXIR-SIDE COPY OF ASSERTION 1 EXISTS
//
// A snapshot is only as fresh as the last refresh, and this workflow
// (.github/workflows/js-tests.yml) is paths-filtered on `js/**` — an API-only
// PR that renames a route touches no js/ path and never runs this file. So the
// real drift LOCK is
// api/test/barkpark_web/contract/sdk_manifest_parity_test.exs: it reads THIS
// fixture (from inside its own tree, where the fixture lives), asserts every
// covered route against the LIVE manifest the app builds, and runs under the
// required Elixir gate on every PR. This file is the consumer-side half — it is
// what guards the SDK surface, which the Elixir side cannot see.
// ─────────────────────────────────────────────────────────────────────────────

import { describe, it, expect } from 'vitest'
import { createClient } from '../src/client'
import type { BarkparkClientConfig } from '../src/types'
import { readFileSync } from 'node:fs'

type CoverageEntry = { sdk_method: string; method: string; path_template: string }
type SdkOnlyEntry = { sdk_method: string; rationale: string }
type ManifestRoute = { command: string; method: string; path_template: string }

const FIXTURE_URL = new URL(
  '../../../../api/test/support/fixtures/sdk-capabilities-parity.json',
  import.meta.url,
)

const fixture = JSON.parse(readFileSync(FIXTURE_URL, 'utf8')) as {
  manifest_routes: ManifestRoute[]
  coverage: CoverageEntry[]
  sdk_only: SdkOnlyEntry[]
}

const manifestRoutes = fixture.manifest_routes
const coverage = fixture.coverage
const sdkOnly = fixture.sdk_only

// Placeholder NAMES differ between the two surfaces on purpose (`:id` in the
// SDK path builders, `:doc_id` / `:rev_id` / `:asset_id` in the manifest), and
// a rename of a placeholder is not a wire change. Collapse every placeholder to
// `:*` so the comparison is over path SHAPE.
function normalizePath(path: string): string {
  return path
    .split('/')
    .map((seg) => (seg.startsWith(':') || seg.startsWith('*') ? ':*' : seg))
    .join('/')
    .replace(/^\/w\/:\*\/p\/:\*/, '') // the workspace-scoped mirror of a flat route
}

const key = (method: string, path: string) => `${method.toUpperCase()} ${normalizePath(path)}`

const validConfig: BarkparkClientConfig = {
  projectUrl: 'http://localhost:4000',
  dataset: 'production',
  apiVersion: '2026-04-01',
}

// The live SDK surface, read off a real client: top-level keys plus the nested
// `auth.*` namespace, spelled the way the fixture spells them.
function sdkSurface(): string[] {
  const client = createClient(validConfig) as unknown as Record<string, unknown>
  const names: string[] = []
  for (const k of Object.keys(client)) {
    if (k === 'auth') continue
    names.push(`client.${k}`)
  }
  const auth = client.auth as Record<string, unknown> | undefined
  for (const k of Object.keys(auth ?? {})) names.push(`client.auth.${k}`)
  return names.sort()
}

describe('SDK ↔ capabilities manifest parity', () => {
  // Positive control. Every assertion below is a "for each" over a list read
  // from a JSON file; an empty read passes all of them for free. A resolved
  // import of a truncated/mis-pathed fixture is exactly how that happens.
  it('the comparison is not vacuous', () => {
    expect(manifestRoutes.length).toBeGreaterThan(100)
    expect(coverage.length).toBeGreaterThan(50)
    expect(sdkOnly.length).toBeGreaterThan(0)
    expect(sdkSurface().length).toBeGreaterThan(50)
  })

  it('every covered route exists in the capabilities manifest', () => {
    const manifestKeys = new Set(manifestRoutes.map((r) => key(r.method, r.path_template)))
    const dangling = coverage.filter((c) => !manifestKeys.has(key(c.method, c.path_template)))

    expect(
      dangling.map((c) => `${c.sdk_method} -> ${c.method} ${c.path_template}`),
      'These SDK methods promise a route the capabilities manifest no longer serves. ' +
        'Either the route was renamed/removed server-side (fix the SDK), or the fixture ' +
        'is stale (refresh it — see the header).',
    ).toEqual([])
  })

  it('every SDK method is either covered or explicitly allow-listed', () => {
    const classified = new Set([
      ...coverage.map((c) => c.sdk_method),
      ...sdkOnly.map((s) => s.sdk_method),
    ])
    const unclassified = sdkSurface().filter((name) => !classified.has(name))

    expect(
      unclassified,
      'These methods exist on BarkparkClient but appear in neither `coverage` nor ' +
        '`sdk_only` in tests/fixtures/capabilities.json. Add a coverage entry naming the ' +
        'HTTP method + path template it calls, or an sdk_only entry with the rationale.',
    ).toEqual([])
  })

  it('every coverage and allow-list entry names a real SDK method', () => {
    const surface = new Set(sdkSurface())
    const phantom = [
      ...coverage.map((c) => c.sdk_method),
      ...sdkOnly.map((s) => s.sdk_method),
    ].filter((name) => !surface.has(name))

    expect(
      phantom,
      'These fixture entries name an SDK method that no longer exists on BarkparkClient. ' +
        'A stale entry silently absolves a future method that reuses the name — delete it.',
    ).toEqual([])
  })

  it('every allow-list entry states a rationale', () => {
    const unexplained = sdkOnly.filter((s) => !s.rationale || s.rationale.trim().length < 20)
    expect(unexplained.map((s) => s.sdk_method)).toEqual([])
  })
})
