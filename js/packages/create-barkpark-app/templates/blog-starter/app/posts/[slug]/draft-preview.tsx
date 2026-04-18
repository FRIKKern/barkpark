'use client'

import { useOptimisticDocument } from '@barkpark/nextjs/actions'
import { PortableText } from '@barkpark/react'

interface Author {
  _id: string
  name: string
}

interface Tag {
  _id: string
  name: string
  slug?: { current: string }
}

interface Post {
  _id: string
  _type: string
  title: string
  excerpt?: string
  publishedAt?: string
  content?: Parameters<typeof PortableText>[0]['value']
}

/**
 * Commit the optimistic edit locally. Replace with a server action that calls
 * `defineActions().patchDoc(id, { set: patch })` once you want preview edits
 * to persist back to the API.
 */
async function commitOptimistic(doc: Post): Promise<Post> {
  return doc
}

interface Props {
  initialPost: Post
  author: Author | null
  tags: Tag[]
}

export function DraftModePreview({ initialPost, author, tags }: Props) {
  const { data, pending, mutate } = useOptimisticDocument<Post>(initialPost, commitOptimistic)

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between rounded border border-amber-300 bg-amber-50 px-4 py-2 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-100">
        <span>
          Draft preview{pending ? ' · saving…' : ''} — editing {data._type}/{data._id}
        </span>
        <form action="/api/exit-preview" method="POST">
          <button type="submit" className="underline">
            Exit preview
          </button>
        </form>
      </div>

      <div className="flex gap-2 text-xs">
        <button
          type="button"
          onClick={() => mutate({ title: `${data.title} (edited)` })}
          className="rounded border border-slate-300 px-2 py-1 dark:border-slate-700"
        >
          Optimistic edit title
        </button>
      </div>

      <article className="prose max-w-none dark:prose-invert">
        <h1 className="text-4xl font-bold">{data.title}</h1>
        {data.publishedAt ? (
          <p className="text-sm text-slate-500">
            {new Date(data.publishedAt).toLocaleDateString()}
            {author ? ` · ${author.name}` : ''}
          </p>
        ) : null}
        {tags.length > 0 ? (
          <p className="flex flex-wrap gap-2 text-xs">
            {tags.map((t) => (
              <span key={t._id} className="rounded bg-slate-100 px-2 py-0.5 dark:bg-slate-800">
                #{t.name}
              </span>
            ))}
          </p>
        ) : null}
        {data.excerpt ? <p className="text-lg">{data.excerpt}</p> : null}
        {data.content ? <PortableText value={data.content} /> : null}
      </article>
    </div>
  )
}
