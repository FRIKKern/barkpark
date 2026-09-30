import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { renderTemplate } from '../src/scaffold'

/**
 * Stranger walk, 2026-09-30: each starter README's Quick start said
 * `{{pmCommand}} install`, and pmCommand is the RUN prefix. For npm that renders
 * `npm run install`, which fails with `Missing script: "install"` — the second
 * command a new user types after `docker compose up -d`. Every Quick start line
 * must be a command the chosen package manager actually runs.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES_DIR = path.resolve(HERE, '..', 'templates')

const RUN_PREFIXES = ['npm run', 'pnpm', 'yarn', 'bun run']

async function starterReadmes(): Promise<Array<[string, string]>> {
  const out: Array<[string, string]> = []
  for (const e of await fs.readdir(TEMPLATES_DIR, { withFileTypes: true })) {
    if (!e.isDirectory() || e.name.startsWith('_')) continue
    const p = path.join(TEMPLATES_DIR, e.name, 'README.md')
    try {
      out.push([e.name, await fs.readFile(p, 'utf8')])
    } catch {
      // a starter without a README has no quick start to check
    }
  }
  return out
}

describe('starter README quick start', () => {
  it('covers at least the two shipped starters (non-vacuous)', async () => {
    expect((await starterReadmes()).length).toBeGreaterThanOrEqual(2)
  })

  for (const pm of RUN_PREFIXES) {
    it(`renders no "<run> install" for ${pm}`, async () => {
      for (const [name, raw] of await starterReadmes()) {
        const rendered = renderTemplate(raw, {
          projectName: 'fixture',
          packageName: 'fixture',
          pmCommand: pm,
          barkparkVersion: '0.0.0',
        })
        expect(rendered, `${name}: "${pm} install" is not an install command for npm/bun`).not.toMatch(
          /^(npm run|bun run) install\b/m,
        )
      }
    })
  }
})
