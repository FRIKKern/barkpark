'use server'

import { defineActions } from '@barkpark/nextjs/actions'
import { barkparkClient } from '../../barkpark.config'
import { resolveServerToken } from '../../lib/resolve-server-token'
import { publicSubmissionMessage, serverLogDetail } from '../../lib/submission-error'

/**
 * `barkpark.config.ts` builds a TOKENLESS client on purpose — it is the shared,
 * read-only config, and anonymous reads of a public dataset need no credential.
 * But `POST /v1/data/mutate/:dataset` ALWAYS requires one, so a tokenless client
 * makes every contact submission fail with a 401 on a freshly scaffolded site.
 *
 * The server token is attached HERE rather than in `barkpark.config.ts` so the
 * credential never enters a module a client component could import: this file is
 * `'use server'`, so it only ever executes on the server, and the read path does
 * the same thing (`lib/barkpark.ts` passes `resolveServerToken(process.env)` to
 * `createBarkparkServer`). Same precedent, same env var — `BARKPARK_SERVER_TOKEN`.
 */
const actions = defineActions({
  client: barkparkClient.withConfig({ token: resolveServerToken(process.env) }),
})

export interface ContactFormState {
  ok: boolean
  message: string
}

export async function submitContact(
  _prev: ContactFormState,
  formData: FormData,
): Promise<ContactFormState> {
  const name = String(formData.get('name') ?? '').trim()
  const email = String(formData.get('email') ?? '').trim()
  const message = String(formData.get('message') ?? '').trim()

  if (name.length === 0 || email.length === 0 || message.length === 0) {
    return { ok: false, message: 'All fields are required.' }
  }

  try {
    await actions.createDoc({
      _type: 'contact',
      name,
      email,
      message,
      receivedAt: new Date().toISOString(),
    })
    return { ok: true, message: 'Thanks \u2014 we\u2019ll be in touch.' }
  } catch (err) {
    // The visitor is anonymous. The upstream error text can name the API host,
    // the dataset, workspace/project slugs, schema fields, or why a bearer token
    // was rejected — so it goes to the SERVER log, and the visitor gets one
    // fixed sentence that is not derived from it. See lib/submission-error.ts.
    console.error('[contact] submission failed:', serverLogDetail(err))
    return { ok: false, message: publicSubmissionMessage(err) }
  }
}
