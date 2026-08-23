// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { execFile } from 'node:child_process'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { promisify } from 'node:util'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { dirname, resolve, join } from 'node:path'
import { describe, expect, it } from 'vitest'

const exec = promisify(execFile)
const here = dirname(fileURLToPath(import.meta.url))
const fixturePath = resolve(here, 'fixtures/production-schema.json')
const cliPath = resolve(here, '../dist/cli.mjs')

/**
 * The ADVERTISED format (cca-backlog-ts-config-loader): `--config` help names
 * barkpark.config.{ts,js,mjs} and defineConfig's own JSDoc example is a .ts
 * file, but no loader was registered — on the Node 20 engines floor every .ts
 * config threw ERR_UNKNOWN_FILE_EXTENSION, and Node 22's type-stripping still
 * rejects non-erasable syntax (an enum throws
 * ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX). .ts/.mts/.cts configs now load via jiti.
 *
 * DELIBERATELY A SUBPROCESS TEST against the BUILT cli.mjs, like
 * cli-from.test.ts: an in-process vitest import of a .ts file is transpiled by
 * Vite's module runner, so an in-process version of this test passes with the
 * jiti branch REMOVED and proves nothing (measured). This one reds without the
 * branch on every supported Node: the enum is non-erasable, so not even a
 * type-stripping host can carry it.
 */
describe('generate --config barkpark.config.ts (the advertised format, built CLI)', () => {
  it('loads a .ts config carrying non-erasable syntax (enum) and writes the output it names', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'bp-codegen-tscfg-'))
    const configPath = join(dir, 'barkpark.config.ts')
    const out = join(dir, 'from-ts-config.types.ts')
    writeFileSync(
      configPath,
      [
        'enum Flavor {', // non-erasable TS — type-stripping cannot load this
        "  Prod = 'production',",
        '}',
        'const config: { dataset: string; output: string } = {',
        '  dataset: Flavor.Prod,',
        `  output: ${JSON.stringify(out)},`,
        '}',
        'export default config',
        '',
      ].join('\n'),
      'utf8',
    )
    await exec('node', [cliPath, 'generate', '--from', fixturePath, '--config', configPath])
    const written = readFileSync(out, 'utf8')
    expect(written).toContain('dataset "production"') // the enum VALUE reached the banner
    expect(written).toContain('export interface')
  })
})
