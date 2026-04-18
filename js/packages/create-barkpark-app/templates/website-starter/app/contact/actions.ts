'use server'

import { defineActions } from '@barkpark/nextjs/actions'
import { barkparkClient } from '../../barkpark.config'

const actions = defineActions({
  client: barkparkClient,
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
    const msg = err instanceof Error ? err.message : 'Unknown error'
    return { ok: false, message: `Submission failed: ${msg}` }
  }
}
