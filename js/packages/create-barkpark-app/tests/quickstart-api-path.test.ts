// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { printNextSteps } from '../src/post-install.js'

/**
 * Owner ruling #60 (2026-10-03; task-984d287af0689251). Both starters told a
 * new user to run `docker compose up -d` first, and that compose file pulls
 * `ghcr.io/barkpark/api:latest`, an image no workflow had ever published — so
 * step 1 failed for everyone without a Barkpark checkout. The quick start now
 * leads with the `bp` CLI; compose is the documented alternative, and the
 * compose file names the secrets the release refuses to boot without.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const TEMPLATES = path.resolve(HERE, '..', 'templates')
const STARTERS = ['blog-starter', 'website-starter']

function quickStartBlock(readme: string): string {
  const section = readme.split('## Quick start')[1] ?? ''
  const fence = section.match(/```sh\n([\s\S]*?)```/)
  return fence ? fence[1] : ''
}

describe('starter quick start leads with bp setup, not docker compose', () => {
  for (const starter of STARTERS) {
    it(`${starter}: the quick-start block installs bp and runs bp setup`, async () => {
      const readme = await fs.readFile(path.join(TEMPLATES, starter, 'README.md'), 'utf8')
      const block = quickStartBlock(readme)
      expect(block, 'no ```sh block under ## Quick start').not.toBe('')
      expect(block).toMatch(/install-cli\.sh \| sh/)
      expect(block).toMatch(/^bp setup --target local --yes/m)
      expect(block).not.toMatch(/docker compose up/)
    })

    it(`${starter}: the Docker alternative names the published image and the secrets`, async () => {
      const readme = await fs.readFile(path.join(TEMPLATES, starter, 'README.md'), 'utf8')
      expect(readme).toContain('ghcr.io/barkpark/api:latest')
      for (const key of [
        'BARKPARK_CLOAK_KEY',
        'BARKPARK_KEK',
        'PREVIEW_JWT_SECRET',
        'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET',
      ]) {
        expect(readme).toContain(key)
      }
    })
  }

  it('the shared compose file refuses by name when a required secret is missing', async () => {
    const compose = await fs.readFile(path.join(TEMPLATES, '_shared', 'docker-compose.yml'), 'utf8')
    for (const key of [
      'BARKPARK_CLOAK_KEY',
      'BARKPARK_KEK',
      'PREVIEW_JWT_SECRET',
      'BARKPARK_RELEASE_CAPTURE_HMAC_SECRET',
    ]) {
      expect(compose).toMatch(new RegExp(`\\$\\{${key}:\\?set ${key} in \\.env`))
    }
  })
})

describe('next steps lead with bp setup', () => {
  afterEach(() => vi.restoreAllMocks())

  it('the local path prints bp setup and no docker compose up', () => {
    const lines: string[] = []
    vi.spyOn(console, 'log').mockImplementation((line?: unknown) => {
      lines.push(String(line ?? ''))
    })
    printNextSteps({
      targetDir: path.resolve(process.cwd(), 'my-site'),
      projectName: 'my-site',
      pm: { name: 'npm', installCommand: 'npm install', runCommand: 'npm run' } as never,
      didInstall: true,
      hostedDemo: false,
    } as never)
    const out = lines.join('\n')
    expect(out).toContain('bp setup --target local --yes')
    expect(out).not.toContain('docker compose up')
  })
})
