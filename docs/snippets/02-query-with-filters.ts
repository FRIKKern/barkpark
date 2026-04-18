// 02-query-with-filters.ts
// Demonstrates the DocsBuilder: where / order / limit / offset / findOne.
//
// Expected: the 5 most-recently-updated published posts whose author is 'Knut',
//   plus the single newest one.

import { createClient, type BarkparkDocument } from '@barkpark/core'

interface Post extends BarkparkDocument {
  title: string
  author: string
  status: string
}

export async function queryPosts(): Promise<{ list: Post[]; first: Post | null }> {
  const client = createClient({
    projectUrl: 'https://cms.example.com',
    dataset: 'production',
    apiVersion: '2026-04-12',
  })

  const list = await client
    .docs<Post>('post')
    .where('author', 'eq', 'Knut')
    .where('status', 'eq', 'published')
    .order('_updatedAt:desc')
    .limit(5)
    .find()

  const first = await client
    .docs<Post>('post')
    .where('author', 'eq', 'Knut')
    .order('_updatedAt:desc')
    .findOne()

  return { list, first }
}
