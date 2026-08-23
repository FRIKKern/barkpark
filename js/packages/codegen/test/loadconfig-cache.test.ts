// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { resolveConfig } from '../src/cli'

/**
 * `barkpark generate --watch` re-enters resolveConfig on every config-file
 * change. The ESM module registry is keyed by URL, so a bare
 * `import(pathToFileURL(abs).href)` hands back the module loaded on the FIRST
 * run: the watcher refetches the OLD dataset, writes the OLD output path, and
 * prints `Re-wrote …` — a false success, not a no-op. loadConfig appends a
 * monotonic cache-bust query so each load resolves to a distinct URL.
 *
 * Reproduced in-process here: the second resolveConfig of a rewritten config
 * must observe the EDITED values. Without the cache-bust this test fails with
 * dataset 'alpha' / output 'A.types.ts' instead of 'beta' / 'B.types.ts'.
 */
describe('loadConfig — a rewritten config is re-read, not served from the ESM cache', () => {
  let dir: string | undefined

  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('returns the edited values on a second resolve of the same path', async () => {
    dir = await mkdtemp(join(tmpdir(), 'bp-codegen-watch-'))
    const configPath = join(dir, 'barkpark.config.mjs')

    await writeFile(
      configPath,
      "export default { dataset: 'alpha', output: 'A.types.ts', apiUrl: 'http://localhost:4000' }\n",
      'utf8',
    )
    const first = await resolveConfig({ config: configPath })
    expect(first).toMatchObject({ dataset: 'alpha', output: 'A.types.ts' })

    // Edit in place — the same path the watcher would see change.
    await writeFile(
      configPath,
      "export default { dataset: 'beta', output: 'B.types.ts', apiUrl: 'http://localhost:4000' }\n",
      'utf8',
    )
    const second = await resolveConfig({ config: configPath })
    expect(second).toMatchObject({ dataset: 'beta', output: 'B.types.ts' })
  })

  it('keeps CLI flags overriding a reloaded config file', async () => {
    dir = await mkdtemp(join(tmpdir(), 'bp-codegen-watch-'))
    const configPath = join(dir, 'barkpark.config.mjs')

    await writeFile(
      configPath,
      "export default { dataset: 'alpha', output: 'A.types.ts', apiUrl: 'http://localhost:4000' }\n",
      'utf8',
    )
    await resolveConfig({ config: configPath })

    await writeFile(
      configPath,
      "export default { dataset: 'beta', output: 'B.types.ts', apiUrl: 'http://localhost:4000' }\n",
      'utf8',
    )
    const second = await resolveConfig({ config: configPath, output: 'flag.types.ts' })
    expect(second).toMatchObject({ dataset: 'beta', output: 'flag.types.ts' })
  })
})

/**
 * The --watch freshness guarantee for jiti-loaded .ts configs
 * (cca-backlog-ts-config-loader). NOTE what this does and does not prove:
 * in-process, Vite's module runner would transpile even a native import of a
 * .ts file, so an in-process test cannot distinguish the jiti branch from the
 * native fallback — the loader-existence proof lives in cli-ts-config.test.ts
 * (built CLI, subprocess). What CAN fail here: jiti's moduleCache/fsCache being
 * turned back on would serve the FIRST config on the second resolve, exactly
 * the stale-watch bug the ?t= cache-bust kills for native loads.
 */
describe('loadConfig — an edited .ts config is re-read (jiti caches off)', () => {
  let dir: string | undefined

  afterEach(async () => {
    if (dir) await rm(dir, { recursive: true, force: true })
    dir = undefined
  })

  it('returns the edited values on a second resolve of the same .ts path', async () => {
    dir = await mkdtemp(join(tmpdir(), 'bp-codegen-ts-'))
    const configPath = join(dir, 'barkpark.config.ts')
    const body = (dataset: string) =>
      `const config: { dataset: string; output: string; apiUrl: string } = {\n  dataset: '${dataset}',\n  output: 'ts.types.ts',\n  apiUrl: 'http://localhost:4000',\n}\nexport default config\n`
    await writeFile(configPath, body('alpha'), 'utf8')
    expect(await resolveConfig({ config: configPath })).toMatchObject({ dataset: 'alpha' })

    await writeFile(configPath, body('beta'), 'utf8')
    expect(await resolveConfig({ config: configPath })).toMatchObject({ dataset: 'beta' })
  })
})
