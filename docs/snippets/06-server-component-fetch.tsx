// 06-server-component-fetch.tsx
// Minimal App Router Server Component backed by createBarkparkServer.
// Shows the dataset cache tag wired into next.tags automatically; passes an
// extra per-type tag via opts.tags for scoped invalidation.
//
// Expected:
//   Server-side fetch hit with next.tags = ['bp:ds:production:_all', 'bp:ds:production:type:post'],
//   cache: 'force-cache', Accept: application/vnd.barkpark+json.

import 'server-only'

import { createClient, type BarkparkDocument } from '@barkpark/core'
import { createBarkparkServer } from '@barkpark/nextjs/server'

const client = createClient({
  projectUrl: 'https://cms.example.com',
  dataset: 'production',
  apiVersion: '2026-04-12',
})

const { barkparkFetch } = createBarkparkServer({
  client,
  serverToken: process.env.BARKPARK_SERVER_TOKEN ?? '',
})

interface Post extends BarkparkDocument {
  title: string
}

export default async function PostsPage(): Promise<React.ReactElement> {
  const posts = await barkparkFetch<Post[]>({
    type: 'post',
    tags: ['bp:ds:production:type:post'],
    revalidate: 3600,
  })

  return (
    <ul>
      {posts.map((p) => (
        <li key={p._id}>{p.title}</li>
      ))}
    </ul>
  )
}
