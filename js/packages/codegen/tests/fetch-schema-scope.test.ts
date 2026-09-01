// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

/**
 * `fetchSchema` is exported from the package root, so it is a first-class
 * programmatic entry point — and until this suite it was the UNGUARDED one.
 *
 * The defect was not "missing validation". `buildSchemaPath` guarded
 * `if (workspace && project)` and, on a half-set pair, fell through to the flat
 * `/v1/schemas/<dataset>` path. So a caller who scoped to a workspace and forgot
 * the project got no error and no warning — their bearer token went to an
 * endpoint they never meant to call, and `barkpark.types.ts` was generated from
 * whatever content model that unscoped endpoint returned. A guard that fails
 * open produces confident wrong output.
 *
 * These tests therefore assert on the EMITTED URL, not merely that something
 * threw: the harm is the request leaving for the wrong place. Every
 * partial-scope case must show `fetchImpl` was never invoked at all.
 */

import { describe, it, expect } from 'vitest'
import { fetchSchema } from '../src/index'

const API = 'https://api.example.test'
const TOKEN = 'test-bearer-token'

/** Envelope shaped to satisfy `schemaEnvelopeSchema` on the success paths. */
const ENVELOPE = {
  _schemaVersion: 2,
  datasetSchemaHash: 'deadbeefdeadbeef',
  schemas: [{ name: 'post', fields: [] }],
}

/** A `fetch` stand-in that records every URL it is asked for. */
function recordingFetch(urls: string[]): typeof fetch {
  return ((url: string) => {
    urls.push(url)
    return Promise.resolve(
      new Response(JSON.stringify(ENVELOPE), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )
  }) as unknown as typeof fetch
}

const PAIR_ERROR = /workspace and project must be set together/

describe('fetchSchema — scope pair is both-or-neither', () => {
  // ---- The subject must be PRESENT: deleting fetchSchema cannot go green. ----

  it('emits the fully scoped URL when workspace AND project are both set', async () => {
    const urls: string[] = []
    await fetchSchema({
      dataset: 'production',
      apiUrl: API,
      token: TOKEN,
      workspace: 'acme',
      project: 'site',
      fetchImpl: recordingFetch(urls),
    })
    expect(urls).toEqual(['https://api.example.test/w/acme/p/site/v1/schemas/production'])
  })

  it('emits the flat back-compat URL when NEITHER is set', async () => {
    const urls: string[] = []
    await fetchSchema({
      dataset: 'production',
      apiUrl: API,
      token: TOKEN,
      fetchImpl: recordingFetch(urls),
    })
    expect(urls).toEqual(['https://api.example.test/v1/schemas/production'])
  })

  // ---- The half-set cases: refuse, and never let the request leave. ----

  it('refuses workspace-only — and the bearer never leaves for the unscoped URL', async () => {
    const urls: string[] = []
    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: API,
        token: TOKEN,
        workspace: 'acme',
        fetchImpl: recordingFetch(urls),
      }),
    ).rejects.toThrow(PAIR_ERROR)
    // The whole point: no request at all — least of all to /v1/schemas/production.
    expect(urls).toEqual([])
  })

  it('refuses project-only — and the bearer never leaves for the unscoped URL', async () => {
    const urls: string[] = []
    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: API,
        token: TOKEN,
        project: 'site',
        fetchImpl: recordingFetch(urls),
      }),
    ).rejects.toThrow(PAIR_ERROR)
    expect(urls).toEqual([])
  })

  // An EXPLICIT `undefined` own-property is not the same thing as an absent one
  // to a caller spreading a partially-filled config, and the old `&&` treated
  // them alike.
  //
  // Note what the cast below is admitting: `exactOptionalPropertyTypes` means
  // TypeScript REFUSES to let us write `project: undefined` literally, so a
  // TS-typed caller is already warned. That is exactly why the guard has to be a
  // runtime check — this package ships to plain-JS callers who get no such
  // warning, and a type does not close the hole for them. The cast reproduces
  // the object shape those callers actually construct.
  type FetchArgs = Parameters<typeof fetchSchema>[0]

  it('refuses an explicitly-undefined project beside a set workspace', async () => {
    const urls: string[] = []
    const args = {
      dataset: 'production',
      apiUrl: API,
      token: TOKEN,
      workspace: 'acme',
      project: undefined,
      fetchImpl: recordingFetch(urls),
    } as unknown as FetchArgs
    expect('project' in (args as object)).toBe(true) // the own property really is there
    await expect(fetchSchema(args)).rejects.toThrow(PAIR_ERROR)
    expect(urls).toEqual([])
  })

  it('refuses an explicitly-undefined workspace beside a set project', async () => {
    const urls: string[] = []
    const args = {
      dataset: 'production',
      apiUrl: API,
      token: TOKEN,
      workspace: undefined,
      project: 'site',
      fetchImpl: recordingFetch(urls),
    } as unknown as FetchArgs
    expect('workspace' in (args as object)).toBe(true)
    await expect(fetchSchema(args)).rejects.toThrow(PAIR_ERROR)
    expect(urls).toEqual([])
  })

  // An empty-string half is the same fail-open shape reached by a different
  // route: `''` is falsy, so `workspace && project` also dropped it to the flat
  // path. `@barkpark/core` catches this half a step earlier, in its slug check.

  it('refuses an empty-string workspace beside a set project', async () => {
    const urls: string[] = []
    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: API,
        token: TOKEN,
        workspace: '',
        project: 'site',
        fetchImpl: recordingFetch(urls),
      }),
    ).rejects.toThrow(PAIR_ERROR)
    expect(urls).toEqual([])
  })

  it('refuses an empty-string project beside a set workspace', async () => {
    const urls: string[] = []
    await expect(
      fetchSchema({
        dataset: 'production',
        apiUrl: API,
        token: TOKEN,
        workspace: 'acme',
        project: '',
        fetchImpl: recordingFetch(urls),
      }),
    ).rejects.toThrow(PAIR_ERROR)
    expect(urls).toEqual([])
  })
})
