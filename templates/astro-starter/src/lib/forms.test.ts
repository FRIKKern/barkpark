import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import {
  CONTACT_FIELDS,
  HONEYPOT_FIELD,
  FormsConfigError,
  outcomeFor,
  resolveFormsUrl,
  submitContactForm,
} from './forms.ts'

/**
 * THE CONTACT FORM'S OPT-IN (task-71082f5541c13b53, N-08).
 *
 * The form exists on the built page only when the deploy engine hands the build
 * BARKPARK_FORMS_URL, which the control plane does only for a site whose owner
 * turned forms on. So the OFF state is the default, and a present-but-wrong
 * value fails the build instead of shipping a form that posts nowhere.
 */

const URL_OK =
  'https://acme.barkpark.cloud/v1/plugins/forms/w/acme/p/blog/d/production/sites/my-blog/submissions'

test('forms are OFF unless BARKPARK_FORMS_URL is set', () => {
  assert.equal(resolveFormsUrl({}), null)
  assert.equal(resolveFormsUrl({ BARKPARK_FORMS_URL: '' }), null)
  assert.equal(resolveFormsUrl({ BARKPARK_FORMS_URL: '   ' }), null)
})

test('a well-formed intake URL is the form action', () => {
  assert.equal(resolveFormsUrl({ BARKPARK_FORMS_URL: URL_OK }), URL_OK)
  assert.equal(resolveFormsUrl({ BARKPARK_FORMS_URL: `  ${URL_OK}\n` }), URL_OK)
})

test('a present but malformed value fails the build loudly', () => {
  for (const bad of [
    'not a url',
    'ftp://acme.barkpark.cloud/v1/plugins/forms/w/a/p/b/d/c/sites/s/submissions',
    'https://acme.barkpark.cloud/v1/data/mutate/production',
    `${URL_OK}?next=/x`,
    `${URL_OK}#frag`,
    'https://user:pw@acme.barkpark.cloud/v1/plugins/forms/w/a/p/b/d/c/sites/s/submissions',
  ]) {
    assert.throws(() => resolveFormsUrl({ BARKPARK_FORMS_URL: bad }), FormsConfigError, bad)
  }
})

test('the field names are the ones the control plane allow-lists on the endpoint', () => {
  // cloud/lib/barkpark_cloud/sites/forms.ex writes `fields` from @default_fields;
  // the box refuses any other name with a 422, so the two lists must agree.
  const src = readFileSync(
    new URL('../../../../cloud/lib/barkpark_cloud/sites/forms.ex', import.meta.url),
    'utf8',
  )
  const m = src.match(/@default_fields ~w\(([^)]*)\)/)
  assert.ok(m, 'cloud forms.ex no longer declares @default_fields ~w(...)')
  assert.deepEqual([...CONTACT_FIELDS], m[1].trim().split(/\s+/))
  // The honeypot rides the intake's reserved `bp_` prefix, so it can never
  // collide with a real field name.
  assert.equal(HONEYPOT_FIELD, 'bp_hp')
})

test('each intake answer maps to one sentence, and only 201 reads as success', () => {
  assert.equal(outcomeFor(201).ok, true)
  for (const s of [0, 403, 404, 413, 422, 429, 500, 502]) {
    assert.equal(outcomeFor(s).ok, false, String(s))
    assert.ok(outcomeFor(s).message.length > 0)
  }
  assert.match(outcomeFor(429).message, /try again later/i)
  assert.match(outcomeFor(0).message, /connection/i)
})

test('submit posts the entries urlencoded to the action, honeypot included', async () => {
  const seen: { url: string; method: string; body: string }[] = []
  const outcome = await submitContactForm(
    URL_OK,
    [
      ['name', 'Kari'],
      ['email', 'kari@example.com'],
      ['message', 'Hei & hallo'],
      [HONEYPOT_FIELD, ''],
    ],
    async (url, init) => {
      seen.push({ url, method: init.method, body: init.body.toString() })
      return { status: 201 }
    },
  )

  assert.deepEqual(outcome, outcomeFor(201))
  assert.equal(seen.length, 1)
  assert.equal(seen[0].url, URL_OK)
  assert.equal(seen[0].method, 'POST')
  assert.equal(seen[0].body, 'name=Kari&email=kari%40example.com&message=Hei+%26+hallo&bp_hp=')
})

test('a network failure resolves to the connection sentence, never a rejection', async () => {
  const outcome = await submitContactForm(URL_OK, [['name', 'x']], async () => {
    throw new TypeError('Failed to fetch')
  })
  assert.deepEqual(outcome, outcomeFor(0))
})
