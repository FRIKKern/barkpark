// 03-listen-for-updates.ts
// Subscribes to the server-sent-event stream for a document type and logs
// each mutation. Unsubscribes cleanly after 30 seconds.
//
// Expected (over stdout, while the stream is open):
//   [welcome] eventId=evt-0
//   [mutation] post:p1 update rev=r-abc
//   [mutation] post:p2 create rev=r-def
//   …

import { createClient, type BarkparkDocument } from '@barkpark/core'

export async function listenForPostUpdates(): Promise<void> {
  const token = process.env.BARKPARK_TOKEN
  if (token === undefined) throw new Error('BARKPARK_TOKEN is required')

  const client = createClient({
    projectUrl: 'https://cms.example.com',
    dataset: 'production',
    apiVersion: '2026-04-12',
    token,
  })

  interface Post extends BarkparkDocument { title: string }

  const handle = client.listen<Post>()
  const timer = setTimeout(() => handle.unsubscribe(), 30_000)

  try {
    for await (const event of handle) {
      if (event.type === 'welcome') {
        console.log(`[welcome] eventId=${event.eventId}`)
        continue
      }
      console.log(
        `[${event.type}] ${event.documentId ?? '?'} ${event.mutation ?? '?'} rev=${event.rev ?? '-'}`,
      )
    }
  } finally {
    clearTimeout(timer)
  }
}
