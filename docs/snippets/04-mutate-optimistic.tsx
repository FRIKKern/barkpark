// 04-mutate-optimistic.tsx
// Client component that edits a document title with useOptimisticDocument.
// Surfaces a conflict banner when another editor wins the race.
//
// Expected UX:
//   1. User types → title updates instantly (optimistic).
//   2. Server action returns → committed state replaces optimistic.
//   3. On BarkparkConflictError → `conflict` populated, banner shown.

'use client'

import { useOptimisticDocument } from '@barkpark/nextjs/actions'
import type { BarkparkDocument } from '@barkpark/core'

interface Post extends BarkparkDocument {
  title: string
}

type SaveAction = (optimistic: Post) => Promise<Post>

export function OptimisticTitleEditor({
  post,
  save,
}: {
  post: Post
  save: SaveAction
}) {
  const { data, pending, conflict, mutate, clearConflict } =
    useOptimisticDocument<Post>(post, save)

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault()
        const form = new FormData(e.currentTarget)
        const title = String(form.get('title') ?? '')
        mutate({ title })
      }}
    >
      <input name="title" defaultValue={data.title} />
      <button type="submit" disabled={pending}>
        {pending ? 'Saving…' : 'Save'}
      </button>

      {conflict !== undefined ? (
        <p role="alert">
          Someone else saved first.
          <button type="button" onClick={clearConflict}>
            Dismiss
          </button>
        </p>
      ) : null}
    </form>
  )
}
