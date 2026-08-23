// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync } from 'node:fs'
import { promisify } from 'node:util'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { dirname, resolve, join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { generateTypes } from '../src/generate'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const fixturePath = resolve(here, 'fixtures/production-schema.json')
const cliPath = resolve(here, '../dist/cli.mjs')

/**
 * cca-backlog-pinned-collator: the three name sorts (composite subs, fields,
 * schemas) used bare `localeCompare`, whose locale is the HOST's — the drift
 * gate runs with no LANG/LC_ALL pin, so emitted order was in principle a
 * function of the machine. Every sort now goes through one pinned
 * Intl.Collator('en-US'), proven byte-identical to the committed artifact.
 */
describe('name collation is pinned, never the host locale', () => {
  it('the measured flip pairs sort in the pinned collation order (reds under a code-unit sort)', async () => {
    // The finding's two live pairs: under a code-unit sort 'runRuleset' <
    // 'rune' ('R' 0x52 < 'e' 0x65) and 'contributorStatement' <
    // 'contributors' — the pinned en-US collation orders them the other way.
    const out = await generateTypes({
      _schemaVersion: 1,
      datasetSchemaHash: 'h',
      schemas: [
        { name: 'runRuleset', fields: [] },
        { name: 'rune', fields: [] },
        {
          name: 'thing',
          fields: [
            { name: 'contributorStatement', type: 'string', required: true },
            { name: 'contributors', type: 'string', required: true },
          ],
        },
      ],
    })
    expect(out.indexOf('interface Rune ')).toBeLessThan(out.indexOf('interface RunRuleset '))
    expect(out.indexOf('contributors:')).toBeLessThan(out.indexOf('contributorStatement:'))
  })

  // Two full CLI runs (spawn + prettier) in one test: CI runners take ~2.5s
  // per run, so vitest's 5s default red this test on CI while it passed
  // locally. The bound is generous — the test's substance is byte equality,
  // never latency.
  it('the built CLI emits byte-identical output under two extreme locale envs', { timeout: 30_000 }, async () => {
    // Cross-locale stability of the SHIPPED binary: LC_ALL=C and a locale with
    // aggressive collation rules must produce the same bytes — the exact
    // stability the un-pinned drift gate was silently assuming.
    // The DRIFT-GATE pair, not the local test fixture: the committed
    // web/lib/barkpark.types.ts is the regen of web/lib/barkpark.schema.json,
    // so that is the input the committed-bytes comparison must use.
    const gateSchema = resolve(here, '../../../../web/lib/barkpark.schema.json')
    const dir = mkdtempSync(join(tmpdir(), 'bp-codegen-collate-'))
    const outputs: string[] = []
    for (const [i, locale] of ['C', 'sv_SE.UTF-8'].entries()) {
      const out = join(dir, `types-${i}.ts`)
      await exec('node', [cliPath, 'generate', '--from', gateSchema, '--dataset', 'production', '--output', out], {
        env: { ...process.env, LANG: locale, LC_ALL: locale },
        // The drift gate's own cwd (js/). Until the output-anchored prettier
        // resolution lands (cca-backlog-prettier-cwd), the config lookup is
        // cwd-relative, and vitest's cwd (packages/codegen) would pick up
        // js/.prettierrc — a DIFFERENT byte-shape than the committed artifact.
        // Pinning the gate's cwd keeps this test about COLLATION, and it stays
        // correct after that fix merges (tmp output → no config → defaults).
        cwd: resolve(here, '../../..'),
      })
      outputs.push(readFileSync(out, 'utf8'))
    }
    expect(outputs[1]).toBe(outputs[0])
    // And they are the COMMITTED artifact's bytes: the pin cost zero regen.
    const committed = readFileSync(resolve(here, '../../../../web/lib/barkpark.types.ts'), 'utf8')
    const md5 = (s: string) => createHash('md5').update(s).digest('hex')
    expect(md5(outputs[0]!)).toBe(md5(committed))
  })
})
