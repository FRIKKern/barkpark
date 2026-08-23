// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import { http } from 'msw'
import { server } from './fixtures/server'
import { TEST_BASE_URL, TEST_DATASET, errorResponse, resetFixtures } from './fixtures/handlers'
import { createClient } from '../src/client'
import { BarkparkNotFoundError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

/**
 * The DECIDED list/doc 404 semantics (site-spawner-backlog-core-list-404-
 * swallow; the decision text lives on createDocsOperation's docstring):
 *
 *   200-empty  (public type, zero docs)  → find [] / findOne null — not an error
 *   404        (missing or private TYPE) → find/findOne REJECT, typed — a
 *              misconfiguration the caller must see (D72: leave-throwing)
 *   getDoc 404 (one doc of a valid type) → { data: null } — a data state
 *
 * This matrix is what makes the deliberate ASYMMETRY between doc.ts and
 * docs.ts a pinned contract instead of an accident.
 */

const baseConfig: BarkparkClientConfig = {
  projectUrl: TEST_BASE_URL,
  dataset: TEST_DATASET,
  apiVersion: '2026-04-17',
}

const queryUrl = (type: string) => `${TEST_BASE_URL}/v1/data/query/${TEST_DATASET}/${type}`
const docUrl = (type: string, id: string) =>
  `${TEST_BASE_URL}/v1/data/doc/${TEST_DATASET}/${type}/${id}`

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers()
  resetFixtures()
})
afterAll(() => server.close())

describe('list/doc 404 semantics (decided: leave-throwing, asymmetry pinned)', () => {
  it('200-empty control: a public type with zero docs finds [] and findOnes null', async () => {
    server.use(
      http.get(queryUrl('empty_type'), () =>
        Response.json({ documents: [], count: 0, limit: 100, offset: 0 }),
      ),
    )
    const bp = createClient(baseConfig)
    expect(await bp.docs('empty_type').find()).toEqual([])
    expect(await bp.docs('empty_type').findOne()).toBeNull()
  })

  it('404-missing control: an unknown type REJECTS find() with the typed error', async () => {
    server.use(
      http.get(queryUrl('no_such_type'), () =>
        errorResponse({ status: 404, code: 'not_found', message: 'unknown type no_such_type' }),
      ),
    )
    const err = await createClient(baseConfig)
      .docs('no_such_type')
      .find()
      .then(
        () => {
          throw new Error('resolved — the 404 was swallowed into an empty list')
        },
        (e: unknown) => e,
      )
    expect(err).toBeInstanceOf(BarkparkNotFoundError)
    expect((err as BarkparkNotFoundError).status).toBe(404)
  })

  it('404-private control: a private type REJECTS findOne() the same way, serverCode intact', async () => {
    server.use(
      http.get(queryUrl('secret_type'), () =>
        errorResponse({ status: 404, code: 'not_found', message: 'type secret_type is private' }),
      ),
    )
    const err = await createClient(baseConfig)
      .docs('secret_type')
      .findOne()
      .then(
        () => {
          throw new Error('resolved — the 404 was swallowed into null')
        },
        (e: unknown) => e,
      )
    expect(err).toBeInstanceOf(BarkparkNotFoundError)
    expect((err as BarkparkNotFoundError).serverCode).toBe('not_found')
  })

  it('getDoc keeps its side of the asymmetry: a 404 for ONE doc is { data: null }', async () => {
    server.use(
      http.get(docUrl('post', 'gone'), () =>
        errorResponse({ status: 404, code: 'not_found', message: 'no such doc' }),
      ),
    )
    expect(await createClient(baseConfig).doc('post', 'gone')).toBeNull()
  })
})
