// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Guard for the published-preview advisory (task-2abbac8d7975050c, PDS-D700).
//
// #9601 repaired `BarkparkReference`'s reference-error collapse and then wrote,
// in its PR body AND in its pending changeset, that the PUBLISHED tarball does
// not contain the collapse. That is false by measurement:
//
//   $ npm pack @barkpark/react@1.0.0-preview.1
//   $ tar xzf barkpark-react-1.0.0-preview.1.tgz
//   $ sed -n '19,40p' package/dist/index.mjs
//   function resolveFetcher(props) {
//     ...
//       return async (id) => {
//         try {
//           return await fetchRaw(`/v1/data/doc/production/${id}`);
//         } catch {
//           return null;                      // <-- the collapse, in SHIPPED js
//         }
//       };
//     ...
//   function AsyncResolve(props) {
//     ...
//     if (doc == null) return createElement(Fragment, null, notFound);
//
// The published dist is NOT minified, so this is hand-written-equivalent output,
// not something read out of a sourcemap. `dist/index.cjs` carries it too, and
// 1.0.0-preview.0 ships a byte-identical src/Reference.tsx (sha1 b7ba6f1d…,
// 6094 B) — so no published version is free of it.
//
// This test pins the two things a reader can actually be misled by:
//   1. the package README must carry the advisory, because the README is what
//      npm renders on the package page and it is one of the three things this
//      package's `files` field ships;
//   2. no changelog-bound text may re-assert that the published artifact is
//      clean — the pending changeset becomes the published CHANGELOG, so the
//      false claim would otherwise ship to npm even though the code is fixed.
//
// NON-VACUITY: the changelog corpus is asserted non-empty before it is scanned.
// A pass that scanned zero files would agree with a deleted CHANGELOG.

import { readFile, readdir } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { describe, it, expect } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const README = join(here, '..', 'README.md')
const CHANGELOG = join(here, '..', 'CHANGELOG.md')
// tests -> react -> packages -> js/.changeset
const CHANGESET_DIR = join(here, '..', '..', '..', '.changeset')

/** Every published version of this package. Both carry the collapse. */
const AFFECTED = ['1.0.0-preview.0', '1.0.0-preview.1']

/**
 * Assertions that the published artifact is free of the defect. Each one is
 * false by measurement; none may appear in text that becomes the CHANGELOG.
 */
const REFUTED_CLAIMS = [
  'does not contain the collapse',
  'owes no deprecation cycle',
  'corrects unreleased behaviour',
  'corrects unreleased behavior',
]

describe('published preview advisory (task-2abbac8d7975050c)', () => {
  it('the README carries the advisory and names BOTH published previews', async () => {
    const readme = await readFile(README, 'utf8')

    expect(
      readme.includes('## Published preview advisory'),
      'js/packages/react/README.md has no "## Published preview advisory" section. ' +
        'Both published versions ship the reference-error collapse and the repair is unreleased; ' +
        'the README is the only page an npm consumer sees, so the advisory lives there.',
    ).toBe(true)

    for (const version of AFFECTED) {
      expect(
        readme.includes(version),
        `The advisory does not name ${version}. Both published previews ship a byte-identical ` +
          'src/Reference.tsx, so naming only one implies the other is clean.',
      ).toBe(true)
    }

    expect(
      readme.includes('npm pack @barkpark/react@'),
      'The advisory must cite the command that obtains the published artifact (`npm pack`), ' +
        'so the claim descends from a measurement a reader can repeat.',
    ).toBe(true)

    expect(
      /catch\s*\{[\s\S]{0,80}return null/.test(readme),
      'The advisory must quote the collapse from the published dist/index.mjs verbatim ' +
        '(the bare `catch { return null }`), not merely describe it.',
    ).toBe(true)
  })

  it('no changelog-bound text claims the published artifact is free of the collapse', async () => {
    // Corpus: the published CHANGELOG plus every pending changeset. Pending
    // changesets are consumed by `changeset version`, so the set can legitimately
    // be empty — the CHANGELOG is what makes the corpus non-vacuous.
    expect(existsSync(CHANGELOG), `${CHANGELOG} is missing — the corpus for this guard is empty.`).toBe(true)

    const corpus: Array<{ path: string; text: string }> = []
    const changelog = await readFile(CHANGELOG, 'utf8')
    expect(changelog.length, 'CHANGELOG.md is empty — nothing was actually scanned.').toBeGreaterThan(0)
    corpus.push({ path: CHANGELOG, text: changelog })

    if (existsSync(CHANGESET_DIR)) {
      const entries = await readdir(CHANGESET_DIR)
      for (const name of entries) {
        if (!name.endsWith('.md') || name.toUpperCase() === 'README.MD') continue
        corpus.push({ path: join(CHANGESET_DIR, name), text: await readFile(join(CHANGESET_DIR, name), 'utf8') })
      }
    }

    expect(corpus.length, 'scanned zero files — the guard would pass vacuously').toBeGreaterThan(0)

    const hits: string[] = []
    for (const { path, text } of corpus) {
      const flat = text.replace(/\s+/g, ' ').toLowerCase()
      for (const claim of REFUTED_CLAIMS) {
        if (flat.includes(claim)) hits.push(`${path}: "${claim}"`)
      }
    }

    expect(
      hits,
      'Text bound for the published CHANGELOG asserts that @barkpark/react as published is free of ' +
        'the reference-error collapse. It is not: `npm pack @barkpark/react@1.0.0-preview.1` ships ' +
        '`try { return await fetchRaw(...) } catch { return null }` in dist/index.mjs, and preview.0 ' +
        'ships a byte-identical src/Reference.tsx. Rewrite the claim to the measured truth.',
    ).toEqual([])
  })
})
