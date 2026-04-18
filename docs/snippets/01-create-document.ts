// 01-create-document.ts
// Creates a draft post via a transaction, then publishes it.
// Runs against any HTTP endpoint the configured client can reach.
//
// Expected:
//   { transactionId: 'tx-…', results: [ { id: 'post-1', operation: 'create', document: { … } } ] }
//   { id: 'post-1', operation: 'publish', document: { _id: 'post-1', _draft: false, … } }

import { createClient } from '@barkpark/core'

export async function createAndPublishPost(): Promise<void> {
  const token = process.env.BARKPARK_TOKEN
  if (token === undefined) throw new Error('BARKPARK_TOKEN is required')

  const client = createClient({
    projectUrl: 'https://cms.example.com',
    dataset: 'production',
    apiVersion: '2026-04-12',
    token,
  })

  const envelope = await client
    .transaction()
    .create({ _id: 'post-1', _type: 'post', title: 'Hello Barkpark' })
    .commit()

  const created = envelope.results[0]
  if (created === undefined) throw new Error('transaction produced no results')

  await client.publish(created.id, 'post')
}
