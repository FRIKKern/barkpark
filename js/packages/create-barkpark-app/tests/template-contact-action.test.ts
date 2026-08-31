import { describe, it, expect } from 'vitest'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  SUBMISSION_FAILED_MESSAGE,
  publicSubmissionMessage,
  serverLogDetail,
} from '../templates/website-starter/lib/submission-error'

/**
 * Shipped bug, two halves, both on the same anonymous surface — the contact
 * form of a freshly scaffolded website-starter.
 *
 * HALF ONE — it could never work. `app/contact/actions.ts` built
 * `defineActions({ client: barkparkClient })`, and `barkpark.config.ts` builds
 * that client with `createClient({ projectUrl, dataset, apiVersion })` and NO
 * token. `POST /v1/data/mutate/:dataset` always requires one (anonymous callers
 * may read a public dataset, never write to it), so every submission on a fresh
 * scaffold failed. The READ path in the same template already resolves a server
 * token (`lib/barkpark.ts` -> `createBarkparkServer({ serverToken:
 * resolveServerToken(process.env) })`); the write path now follows it.
 *
 * HALF TWO — the failure leaked. The catch returned
 * `Submission failed: ${err.message}` straight into the rendered page. On this
 * path `err.message` is the raw upstream answer, which can name the API host,
 * the dataset, workspace/project slugs, schema fields, or why a bearer token was
 * rejected — handed to an anonymous visitor.
 *
 * The message helper is imported from the TEMPLATE itself, so this cannot pass
 * against a template that has drifted back.
 */

const HERE = path.dirname(fileURLToPath(import.meta.url))
const SITE = path.resolve(HERE, '..', 'templates', 'website-starter')
const ACTIONS = path.join(SITE, 'app', 'contact', 'actions.ts')

/** Upstream error strings shaped like what the mutate endpoint actually returns. */
const LEAKY_ERRORS: [string, unknown][] = [
  [
    'a 401 naming the host and dataset',
    new Error('POST https://cms.internal.example/v1/data/mutate/production failed: 401 unauthorized'),
  ],
  [
    'a validation error naming schema fields',
    new Error('mutate failed: 422 {"errors":{"receivedAt":["is invalid"],"email":["required"]}}'),
  ],
  [
    'a token rejection',
    new Error('bearer token "bp_live_9f2c..." is expired or revoked'),
  ],
  ['a thrown string', 'ECONNREFUSED 10.0.0.7:4000'],
  ['a thrown object with .message', { message: 'workspace acme / project marketing not found' }],
  ['null', null],
]

describe('publicSubmissionMessage: the visitor never receives upstream text', () => {
  it.each(LEAKY_ERRORS)('%s -> the fixed sentence, nothing from the error', (_label, err) => {
    const shown = publicSubmissionMessage(err)
    expect(shown).toBe(SUBMISSION_FAILED_MESSAGE)

    // Prove the leak is actually absent, not merely "a different string": no
    // token from the upstream text of length >= 4 may appear in what is shown.
    const upstream =
      err instanceof Error
        ? err.message
        : typeof err === 'string'
          ? err
          : err && typeof err === 'object' && 'message' in err
            ? String((err as { message: unknown }).message)
            : ''
    const secrets = upstream.split(/[\s"{}[\],:]+/).filter((t) => t.length >= 4)
    for (const s of secrets) {
      expect(shown.toLowerCase()).not.toContain(s.toLowerCase())
    }
  })

  it('the fixed sentence is a real, actionable sentence (not empty)', () => {
    // Guards the other failure mode: silencing the error by showing nothing.
    expect(SUBMISSION_FAILED_MESSAGE.length).toBeGreaterThan(20)
    expect(SUBMISSION_FAILED_MESSAGE).toMatch(/try again/i)
  })

  it('the LEAKY_ERRORS fixture really does carry leakable detail', () => {
    // Non-vacuity: if these errors were blank, every assertion above would pass
    // trivially. Assert the sensitive substrings ARE present in the inputs.
    const all = LEAKY_ERRORS.map(([, e]) =>
      e instanceof Error ? e.message : typeof e === 'string' ? e : JSON.stringify(e),
    ).join(' | ')
    for (const needle of ['cms.internal.example', 'production', 'receivedAt', 'bp_live_', '10.0.0.7']) {
      expect(all).toContain(needle)
    }
  })
})

describe('serverLogDetail: the operator DOES get the detail', () => {
  it('keeps the upstream message for the server log', () => {
    const err = new Error('mutate failed: 401 unauthorized')
    expect(serverLogDetail(err)).toContain('mutate failed: 401 unauthorized')
  })

  it('stringifies a non-Error throw', () => {
    expect(serverLogDetail('ECONNREFUSED')).toBe('ECONNREFUSED')
  })
})

describe('the contact Server Action carries a write credential', () => {
  it('exists and is a server module', async () => {
    const src = await fs.readFile(ACTIONS, 'utf8')
    expect(src.length).toBeGreaterThan(200) // the read is real
    expect(src).toContain("'use server'")
    expect(src).toContain('defineActions')
    expect(src).toContain('createDoc')
  })

  it('passes a token to the client it hands defineActions', async () => {
    const src = await fs.readFile(ACTIONS, 'utf8')
    // The precedent the read path set: resolveServerToken(process.env).
    expect(src).toContain('resolveServerToken')
    expect(src).toContain('token:')
    // The exact shipped defect: a tokenless client handed straight to defineActions.
    expect(src).not.toMatch(/defineActions\(\{\s*client:\s*barkparkClient,?\s*\}\)/)
  })

  it('does not interpolate the upstream error into what it returns', async () => {
    const src = await fs.readFile(ACTIONS, 'utf8')
    expect(src).toContain('publicSubmissionMessage')
    // The exact shipped defect line.
    expect(src).not.toContain('Submission failed: ${msg}')
    // And the class of it: no `err.message` reaching the returned state.
    expect(/message:\s*`[^`]*\$\{\s*(msg|err|error)\b/.test(src)).toBe(false)
  })

  it('logs the detail server-side instead of dropping it', async () => {
    const src = await fs.readFile(ACTIONS, 'utf8')
    expect(src).toContain('console.error')
    expect(src).toContain('serverLogDetail')
  })
})

describe('the document type the form writes is documented', () => {
  it('schemas/contact.ts exists and is not publicly readable', async () => {
    const src = await fs.readFile(path.join(SITE, 'schemas', 'contact.ts'), 'utf8')
    expect(src).toContain("name: 'contact'")
    // Submissions carry a visitor's email address — they must not be served over
    // the anonymous public read path the rest of the site uses.
    expect(src).toContain("visibility: 'private'")
    expect(src).not.toContain("visibility: 'public'")
  })

  it('the form writes exactly the type the schema declares', async () => {
    const actions = await fs.readFile(ACTIONS, 'utf8')
    expect(actions).toContain("_type: 'contact'")
  })
})
