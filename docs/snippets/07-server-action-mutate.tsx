// 07-server-action-mutate.tsx
// Server Action module wiring defineActions + a minimal <form> that submits to it.
// Demonstrates createDoc, patchDoc, and the client-side form binding.
//
// Expected: on submit, a draft post is created, immediately patched with a slug,
// and the page fans out ['bp:ds:production:doc:<id>', 'bp:ds:production:type:post']
// via revalidateTag().

'use server'

import { createClient } from '@barkpark/core'
import { defineActions } from '@barkpark/nextjs/actions'

const token = process.env.BARKPARK_TOKEN
if (token === undefined) throw new Error('BARKPARK_TOKEN is required')

const client = createClient({
  projectUrl: 'https://cms.example.com',
  dataset: 'production',
  apiVersion: '2026-04-12',
  token,
})

const actions = defineActions({ client })

export async function createPostAction(formData: FormData): Promise<void> {
  const title = String(formData.get('title') ?? '').trim()
  if (title.length === 0) throw new Error('title is required')

  const created = await actions.createDoc({ _type: 'post', title })
  await actions.patchDoc(created.id, {
    set: { slug: title.toLowerCase().replace(/[^a-z0-9]+/g, '-') },
  })
}
