// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The two pd-golden mirrors, named ONCE.
//
// `mix barkpark.portable_doc.gen_pd_parity` writes every golden fixture into
// both of them (gen_pd_parity.ex `@fixture_dir` / `@js_dir`). Consumers that
// need "how many types are in the corpus" must derive it from a mirror rather
// than pin a literal: pinned corpus floors are how a mirror goes stale without
// anything reding (`PortableDoc.parity.test.tsx` carried `>= 46` while 65
// fixtures were on disk).
//
// Freshness itself — the two mirrors agreeing — is asserted in
// `tests/pd-golden-mirror-parity.test.ts`.

import { existsSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))

/** JS mirror — what `@barkpark/react`'s parity suites render against. */
export const JS_MIRROR = join(HERE, '..', 'fixtures', 'pd-golden')

/** Elixir mirror — the canonical mint; also what `scripts/pd-parity-completeness.sh` censuses. */
export const ELIXIR_MIRROR = join(
  HERE,
  '..',
  '..',
  '..',
  '..',
  '..',
  'api',
  'test',
  'support',
  'fixtures',
  'pd-parity',
)

export const GOLDEN_SUFFIX = '.golden.json'

/** Sorted `<type>.golden.json` basenames in `dir`; `[]` when the dir is absent. */
export function goldenNames(dir: string): string[] {
  if (!existsSync(dir) || !statSync(dir).isDirectory()) return []
  return readdirSync(dir)
    .filter((f) => f.endsWith(GOLDEN_SUFFIX))
    .sort()
}
