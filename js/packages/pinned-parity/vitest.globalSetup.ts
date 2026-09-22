// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// THE PREREQUISITE LIVES HERE, NOT IN A `test` SCRIPT.
//
// `scripts/prepare-pinned.mjs` materialises the pinned @barkpark/react artifact
// this package's only suite renders through. It used to be chained from
// package.json (`"test": "pnpm run prepare:pinned && vitest run"`), so it ran on
// exactly ONE invocation path: `pnpm --filter @barkpark/pinned-parity test`.
// The monorepo root config (`js/vitest.config.mts`) registers this project by
// its config PATH and inherits nothing from package.json, so the obvious
// newcomer command — `cd js && npx vitest run` — collected the test file with no
// artifact under it. The suite's preflight then did the right thing and threw
// ("Refusing to report a green with no subject"), turning a wiring hole into a
// permanent red on the whole monorepo run.
//
// A `globalSetup` on THIS project's own config is the fix that cannot recur:
// vitest runs it for the project regardless of who invoked it — the package
// script, the root multi-project run, `--project=@barkpark/pinned-parity`, an
// IDE runner, or `js/scripts/check-vitest-projects.mjs`. Nothing upstream has to
// remember the step, which is precisely what the package.json chain required.
//
// The suite's preflight is NOT weakened and must never be: this hook guarantees
// the artifact on every path that goes through this config, and the preflight
// still reds for any path that does not (a bare `vitest run` pointed at the test
// file with another config, a hand-deleted `.pinned/` mid-run, a prepare that
// wrote nothing). Belt and braces, both load-bearing.

import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// `import.meta.dirname` lands only in Node 20.11; this package's engines field
// allows 20.9, so derive the directory the portable way.
const PKG_ROOT = dirname(fileURLToPath(import.meta.url))
const SCRIPT = join(PKG_ROOT, 'scripts', 'prepare-pinned.mjs')
const MANIFEST = join(PKG_ROOT, '.pinned', 'manifest.json')

export default function setup(): void {
  execFileSync(process.execPath, [SCRIPT], {
    cwd: PKG_ROOT,
    stdio: ['ignore', 'inherit', 'inherit'],
  })
  if (!existsSync(MANIFEST)) {
    throw new Error(
      `prepare-pinned.mjs exited 0 but wrote no ${MANIFEST} — refusing to hand the suite a ` +
        'green with no subject.',
    )
  }
}
