// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import path from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { printNextSteps, shellArg } from '../src/post-install.js'

/**
 * Stranger walk (2026-09-30): `create-barkpark-app "Bad Name!" --yes` scaffolds
 * a directory literally named `Bad Name!`, then printed `cd Bad Name!` as the
 * first next step — two words to the shell (and `!` is history expansion in an
 * interactive bash), so the step failed as pasted. The directory is now one
 * quoted shell word; plain names print exactly as before.
 */
describe('next steps: the cd line is one shell word', () => {
  afterEach(() => vi.restoreAllMocks())

  it('leaves a plain directory name unquoted', () => {
    expect(shellArg('my-barkpark-site')).toBe('my-barkpark-site')
    expect(shellArg('apps/my_site.v2')).toBe('apps/my_site.v2')
  })

  it('single-quotes a name with a space or a shell metacharacter', () => {
    expect(shellArg('Bad Name!')).toBe(`'Bad Name!'`)
    expect(shellArg('a$b')).toBe(`'a$b'`)
  })

  it('closes, escapes and reopens an embedded single quote', () => {
    expect(shellArg("it's")).toBe(`'it'\\''s'`)
  })

  it('printNextSteps prints the quoted cd line', () => {
    const lines: string[] = []
    vi.spyOn(console, 'log').mockImplementation((line?: unknown) => {
      lines.push(String(line ?? ''))
    })
    printNextSteps({
      targetDir: path.resolve(process.cwd(), 'Bad Name!'),
      projectName: 'Bad Name!',
      pm: { name: 'npm', installCommand: 'npm install', runCommand: 'npm run' } as never,
      hostedDemo: false,
      skipGit: true,
      didInstall: true,
    })
    const plain = lines.map((l) => l.replace(/\x1b\[[0-9;]*m/g, ''))
    expect(plain).toContain(`  cd 'Bad Name!'`)
  })
})
