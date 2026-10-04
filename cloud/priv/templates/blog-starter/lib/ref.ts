// A reference value as it is actually stored. `{ _ref: id }` is the canonical
// shape (owner ruling #42): the seeds, the typed client and the Barkpark Studio
// write it. Studio saves made before that ruling stored a bare id (`"ada"`),
// and such a value is only rewritten the next time its document is saved, so
// every reference read goes through here and accepts both.
//
// Dependency-free (no 'server-only', no @barkpark/*): safe in server and client
// components alike, and importable straight from the template source in tests.

/** A reference value in either stored shape. */
export type RefValue = string | { _ref?: string | null; _type?: string } | null | undefined

/** The referenced document id, whichever shape it was stored in; `undefined` when unset. */
export function refOf(ref: RefValue): string | undefined {
  if (typeof ref === 'string') return ref || undefined
  if (ref && typeof ref === 'object' && typeof ref._ref === 'string') {
    return ref._ref || undefined
  }
  return undefined
}
