// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// The contact form's opt-in (task-71082f5541c13b53, N-08). Two halves, one
// module, no dependencies:
//
//   BUILD time  `resolveFormsUrl(env)` reads BARKPARK_FORMS_URL. The deploy
//               engine sets it ONLY for a site whose owner turned forms on in
//               the Barkpark Cloud console; unset, the page renders no form at
//               all. It is the box's PUBLIC intake URL — never a credential —
//               so it is safe to bake into the HTML as the form's `action`.
//   BROWSER     `submitContactForm(form, fetchImpl)` posts the form as
//               `application/x-www-form-urlencoded` (a CORS "simple" request:
//               no preflight, and the browser sends the page's `Origin`, which
//               the intake checks against the endpoint's allowed origins) and
//               `outcomeFor(status)` turns the answer into one sentence.
//
// The field names are a CONTRACT with the endpoint: the box refuses any field
// the endpoint document does not list with a 422, and the control plane writes
// exactly `name`, `email`, `message` (cloud/lib/barkpark_cloud/sites/forms.ex
// `@default_fields`). `bp_hp` is the intake's honeypot: a filled one is
// answered 201 and never stored.

export const CONTACT_FIELDS = ['name', 'email', 'message'] as const
export const HONEYPOT_FIELD = 'bp_hp'

// /v1/plugins/forms/w/:ws/p/:proj/d/:dataset/sites/:site/submissions
const SUBMISSIONS_PATH = /^\/v1\/plugins\/forms\/w\/[^/]+\/p\/[^/]+\/d\/[^/]+\/sites\/[^/]+\/submissions$/

export class FormsConfigError extends Error {}

/**
 * The form's `action`, or `null` when forms are off for this site.
 *
 * Unset or blank is the normal OFF state. A value that is present but is not
 * an http(s) intake URL THROWS: the control plane generates it, so a malformed
 * one is a bug that must fail the build loudly rather than ship a form that
 * posts nowhere.
 */
export function resolveFormsUrl(env: Record<string, string | undefined> = process.env): string | null {
  const raw = env.BARKPARK_FORMS_URL?.trim()
  if (!raw) return null

  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new FormsConfigError(`BARKPARK_FORMS_URL is not a URL: ${JSON.stringify(raw)}`)
  }

  if (
    (url.protocol !== 'https:' && url.protocol !== 'http:') ||
    !SUBMISSIONS_PATH.test(url.pathname) ||
    url.search !== '' ||
    url.hash !== '' ||
    url.username !== '' ||
    url.password !== ''
  ) {
    throw new FormsConfigError(
      `BARKPARK_FORMS_URL must be a Barkpark form intake URL (…/v1/plugins/forms/w/:ws/p/:proj/d/:dataset/sites/:site/submissions), got ${JSON.stringify(raw)}`,
    )
  }

  return url.toString()
}

export interface Outcome {
  ok: boolean
  message: string
}

/** One sentence for the intake's answer. `0` means the request never got an answer. */
export function outcomeFor(status: number): Outcome {
  if (status === 201 || status === 200) return { ok: true, message: 'Thanks — your message was sent.' }
  if (status === 429) return { ok: false, message: 'Too many messages from here just now. Please try again later.' }
  if (status === 413 || status === 422)
    return { ok: false, message: 'That message could not be accepted. Check the fields and try again.' }
  if (status === 403 || status === 404)
    return { ok: false, message: 'This form is not accepting messages right now.' }
  if (status === 0)
    return { ok: false, message: 'Could not send — check your connection and try again.' }
  return { ok: false, message: 'Something went wrong on our side. Please try again in a moment.' }
}

type FetchLike = (url: string, init: { method: string; body: URLSearchParams }) => Promise<{ status: number }>

/**
 * Post `entries` (the form's name/value pairs) to `action`. Resolves to the
 * outcome; never rejects — a network failure is `outcomeFor(0)`.
 */
export async function submitContactForm(
  action: string,
  entries: Iterable<[string, string]>,
  fetchImpl: FetchLike,
): Promise<Outcome> {
  const body = new URLSearchParams()
  for (const [k, v] of entries) body.append(k, v)
  try {
    const res = await fetchImpl(action, { method: 'POST', body })
    return outcomeFor(res.status)
  } catch {
    return outcomeFor(0)
  }
}
