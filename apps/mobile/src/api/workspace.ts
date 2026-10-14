// GET /v1/workspace/locale — the workspace's language, which the PortableDoc
// renderer's own words follow (task-5ba3360aecba7a99). Any member token may
// read it. The route is workspace-scoped, so it answers only when the
// connection names a workspace and project; anything else (an unscoped
// connection, offline, a server without the route) is English, the
// renderer's default.
import { useEffect, useState } from 'react'
import type { BarkparkClient } from '@barkpark/core'

import type { InstanceConnection } from './instance'

export const DEFAULT_LOCALE = 'en'

/** The workspace locale ('en', 'nb-NO', …), or 'en' when it cannot be read. */
export async function fetchWorkspaceLocale(client: BarkparkClient): Promise<string> {
  try {
    const response = await client.fetchRaw<Response>('/v1/workspace/locale')
    if (!response.ok) return DEFAULT_LOCALE
    const body = (await response.json()) as { locale?: unknown }
    return typeof body.locale === 'string' && body.locale !== '' ? body.locale : DEFAULT_LOCALE
  } catch {
    return DEFAULT_LOCALE
  }
}

// One read per connection per app run: the reader and the chat transcript
// both ask, and a language change is rare enough that the next launch picks
// it up.
const cache = new Map<string, Promise<string>>()

/** The workspace locale for `key`'s connection; English until it resolves. */
export function useWorkspaceLocale(client: BarkparkClient, key: string): string {
  const [locale, setLocale] = useState<string>(DEFAULT_LOCALE)

  useEffect(() => {
    let live = true
    let pending = cache.get(key)
    if (pending === undefined) {
      pending = fetchWorkspaceLocale(client)
      cache.set(key, pending)
    }
    void pending.then((value) => {
      if (live) setLocale(value)
    })
    return () => {
      live = false
    }
  }, [client, key])

  return locale
}

/** The cache key for a connection: one workspace's language per entry. */
export function localeKey(connection: InstanceConnection): string {
  return [connection.projectUrl, connection.workspace ?? '', connection.project ?? ''].join('|')
}

/** Test seam: forget every cached read. */
export function resetWorkspaceLocaleCache(): void {
  cache.clear()
}
