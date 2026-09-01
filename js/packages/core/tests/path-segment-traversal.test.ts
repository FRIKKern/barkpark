// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

// A path SEGMENT may not be a relative-path operator.
//
// `encodeURIComponent` does NOT escape `.`, so an id of `'..'` survives every
// path builder in this package intact. The transport concatenates the path and
// hands the string to `fetch`, whose WHATWG URL parser resolves `..` BEFORE the
// request leaves — so an unvalidated caller-supplied id (URL param, form field,
// CSV import, upstream payload) retargets the request at a DIFFERENT endpoint
// than the function name promises. The worst case is destructive:
// `revokeCollectionShare('..')` emitted `DELETE /v1/media/:dataset/share`, which
// the router matches as `delete("/:dataset/:id", MediaController, :delete)` —
// it deletes an asset instead of revoking a share link.
//
// These tests assert the EMITTED URL (resolved exactly as fetch resolves it),
// not merely that a throw happened: the harm is the wrong endpoint, so the proof
// is that no request leaves at all. Each block also pins the NORMAL id path to
// its correct URL, so deleting the guarded function cannot turn these green.

import { describe, it, expect, beforeEach } from 'vitest'
import { createClient } from '../src/client'
import { BarkparkValidationError } from '../src/errors'
import type { BarkparkClientConfig } from '../src/types'

let emitted: string[] = []

// Record what fetch would actually request. `new Request(url)` runs the same
// WHATWG URL parse fetch runs, so `..` is resolved here BY THE RUNTIME — not by
// the test — exactly as it would be on the wire.
const recordingFetch: typeof globalThis.fetch = async (input, init) => {
  const raw = typeof input === 'string' ? input : String((input as Request).url ?? input)
  const u = new URL(new Request(raw).url)
  emitted.push(`${init?.method ?? 'GET'} ${u.pathname}`)
  return new Response(JSON.stringify({ result: { assets: [], count: 0 } }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })
}

const scoped: BarkparkClientConfig = {
  projectUrl: 'https://api.example.com',
  workspace: 'acme',
  project: 'blog',
  dataset: 'production',
  apiVersion: '2026-04-17',
  token: 'tok',
  fetch: recordingFetch,
}

const flat: BarkparkClientConfig = {
  projectUrl: 'https://api.example.com',
  dataset: 'production',
  apiVersion: '2026-04-17',
  token: 'tok',
  fetch: recordingFetch,
}

beforeEach(() => {
  emitted = []
})

describe("media ids: '..' must never reach fetch", () => {
  it('revokeCollectionShare("..") does not emit DELETE /v1/media/:dataset/:id (the DESTRUCTIVE case)', async () => {
    const bp = createClient(scoped)
    await expect(bp.revokeCollectionShare('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    // Before the guard this was ['DELETE /w/acme/p/blog/v1/media/production/share']
    // — MediaController.delete, i.e. an asset deletion, from a "revoke share" call.
    expect(emitted).toEqual([])
  })

  it('the normal collection id still reaches the share endpoint (subject present)', async () => {
    const bp = createClient(scoped)
    await bp.revokeCollectionShare('col-1')
    expect(emitted).toEqual(['DELETE /w/acme/p/blog/v1/media/production/collections/col-1/share'])
  })

  it('getCollection("..") does not collapse onto the collection INDEX', async () => {
    const bp = createClient(scoped)
    await expect(bp.getCollection('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    // Before: ['GET /w/acme/p/blog/v1/media/production/'] -> MediaController.index,
    // which answered with a truthy bogus "collection" where a real miss returns null.
    expect(emitted).toEqual([])
  })

  it('getCollectionAssets("..") does not collapse onto MediaController.show', async () => {
    const bp = createClient(scoped)
    await expect(bp.getCollectionAssets('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    // Before: ['GET /w/acme/p/blog/v1/media/production/assets']
    expect(emitted).toEqual([])
  })

  it('getAssetRelations("..") does not eat the DATASET segment', async () => {
    const bp = createClient(scoped)
    await expect(bp.getAssetRelations('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    // Before: ['GET /w/acme/p/blog/v1/media/relations'] — the client's own dataset
    // pinning defeated by an asset id.
    expect(emitted).toEqual([])
  })

  it('is not scope-specific: the flat/unscoped client collapses identically', async () => {
    const bp = createClient(flat)
    await expect(bp.getCollection('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
    await bp.getAsset('a1')
    expect(emitted).toEqual(['GET /v1/media/production/a1'])
  })

  it('a single "." and a separator-bearing id are rejected too', async () => {
    const bp = createClient(scoped)
    await expect(bp.getAsset('.')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getAsset('a/../b')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getAsset('a\\b')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
  })

  it('a normal asset id is untouched (subject present)', async () => {
    const bp = createClient(scoped)
    await bp.getAsset('a1')
    expect(emitted).toEqual(['GET /w/acme/p/blog/v1/media/production/a1'])
  })

  it('a dotted id that is NOT a relative-path operator still works', async () => {
    const bp = createClient(scoped)
    await bp.getAsset('a.b.c')
    await bp.getAsset('...')
    expect(emitted).toEqual([
      'GET /w/acme/p/blog/v1/media/production/a.b.c',
      'GET /w/acme/p/blog/v1/media/production/...',
    ])
  })
})

describe("the same collapse in the other path builders ('..' never leaves)", () => {
  it('doc() rejects a traversal type and a traversal id', async () => {
    const bp = createClient(scoped)
    await expect(bp.doc('..', 'p1')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.doc('post', '..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
    await bp.doc('post', 'p1')
    expect(emitted).toEqual(['GET /w/acme/p/blog/v1/data/doc/production/post/p1'])
  })

  it('getHistory / getRevision reject traversal segments', async () => {
    const bp = createClient(scoped)
    await expect(bp.getHistory('..', 'p1')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getHistory('post', '..')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getRevision('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
  })

  it('getTagDocs rejects a traversal tag but KEEPS hierarchical `a/b` tags', async () => {
    const bp = createClient(scoped)
    await expect(bp.getTagDocs('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
    // The one deliberate asymmetry: `/` is legitimate content in a tag NAME and
    // encodeURIComponent collapses it into a single `a%2Fb` segment, so the
    // separator ban that applies to ids must not apply here. A guard that
    // over-rejects a shipped capability is a regression, not a fix.
    await bp.getTagDocs('a/b')
    expect(emitted).toEqual(['GET /w/acme/p/blog/v1/data/tags/production/a%2Fb'])
  })

  it('getSchema / deleteSchema reject a traversal name', async () => {
    const bp = createClient(scoped)
    await expect(bp.getSchema('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.deleteSchema('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
  })

  it('getBacklinks / getRelated / getGraph reject a traversal id', async () => {
    const bp = createClient(scoped)
    await expect(bp.getBacklinks('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getRelated('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.getGraph('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
  })

  it('webhook CRUD rejects a traversal id', async () => {
    const bp = createClient(scoped)
    await expect(bp.getWebhook('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    await expect(bp.deleteWebhook('..')).rejects.toBeInstanceOf(BarkparkValidationError)
    expect(emitted).toEqual([])
  })
})
