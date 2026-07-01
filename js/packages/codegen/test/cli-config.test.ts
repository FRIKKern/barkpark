// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { describe, expect, it } from 'vitest'
import { resolveConfig } from '../src/cli'

/**
 * workspace + project are the two halves of a scoped schema path. Supplying
 * only one silently falls back to the flat /v1/schemas/<dataset> path (see
 * buildSchemaPath's back-compat), which emits types for the wrong, unscoped
 * content model. resolveConfig must reject the half-specified case rather than
 * mis-scope in silence.
 */
describe('resolveConfig — workspace/project must be both-or-neither', () => {
  const base = { dataset: 'd', output: 'o', apiUrl: 'u' }

  it('rejects when only workspace is set', async () => {
    await expect(resolveConfig({ ...base, workspace: 'a' })).rejects.toThrow(
      'workspace and project must be provided together',
    )
  })

  it('rejects when only project is set', async () => {
    await expect(resolveConfig({ ...base, project: 'p' })).rejects.toThrow(
      'workspace and project must be provided together',
    )
  })

  it('resolves when both are set', async () => {
    await expect(
      resolveConfig({ ...base, workspace: 'a', project: 'p' }),
    ).resolves.toMatchObject({ dataset: 'd', output: 'o', apiUrl: 'u', workspace: 'a', project: 'p' })
  })

  it('resolves when neither is set', async () => {
    await expect(resolveConfig({ ...base })).resolves.toMatchObject({
      dataset: 'd',
      output: 'o',
      apiUrl: 'u',
    })
  })
})
