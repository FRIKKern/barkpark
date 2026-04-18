// 05-publish-unpublish.ts
// Round-trip publish/unpublish against a single document.
// Uses defineActions() so revalidate tags fan out automatically.
//
// Expected:
//   publish:   { id: 'p1', operation: 'publish',   document: { _id: 'p1', _draft: false, … } }
//   unpublish: { id: 'p1', operation: 'unpublish', document: { _id: 'p1', _draft: true,  … } }

import { createClient, type MutateResult } from '@barkpark/core'
import { defineActions } from '@barkpark/nextjs/actions'

export async function publishRoundTrip(id: string): Promise<{
  published: MutateResult
  unpublished: MutateResult
}> {
  const token = process.env.BARKPARK_TOKEN
  if (token === undefined) throw new Error('BARKPARK_TOKEN is required')

  const client = createClient({
    projectUrl: 'https://cms.example.com',
    dataset: 'production',
    apiVersion: '2026-04-12',
    token,
  })

  const actions = defineActions({ client })

  const published = await actions.publish(id, 'post')
  const unpublished = await actions.unpublish(id, 'post')

  return { published, unpublished }
}
