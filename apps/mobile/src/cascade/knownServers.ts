// Known-servers MRU — a faithful TS transliteration of the bp CLI's connect
// history (internal/cli/config.go: ServerEntry / normalizeServerURL /
// sameEntryIdentity / mergeAliases / RememberServer). The semantics are the
// contract (charter D14):
//
//   - upsert identity is InstanceID-FIRST: when both sides carry one, only the
//     ID decides (case-insensitive) — two hostnames of one instance collapse
//     to ONE entry, never a phantom "-2" second server;
//   - either side lacking an ID falls back to normalized-URL equality against
//     the primary server or any recorded alias;
//   - on re-connect the prior primary URL folds into `aliases` so no URL is
//     ever lost;
//   - the list is most-recent-first, capped at 20;
//   - the flat active-context fields (server/token/workspace/project/dataset)
//     are promoted on every remember — they ARE the last-location memory the
//     app reopens into.

export interface ServerEntry {
  name?: string
  server: string
  /** Stable control-plane instance id — the primary upsert key. Empty when never learned. */
  instanceId?: string
  /** Other hostnames known to reach this same instance (exclusive of `server`). */
  aliases?: string[]
  /** Human name of the owning Cloud team (identity only, never a credential). */
  team?: string
  token?: string
  workspace?: string
  project?: string
  dataset?: string
  /** RFC3339, stamped by the caller — kept verbatim so this stays pure. */
  lastConnected?: string
}

/** The persisted config surface the MRU maintains (mirrors cli Config). */
export interface StoredConfig {
  server?: string
  token?: string
  workspace?: string
  project?: string
  dataset?: string
  cloudUrl?: string
  cloudToken?: string
  cloudTeam?: string
  knownServers?: ServerEntry[]
}

export const MAX_KNOWN_SERVERS = 20

/**
 * Canonicalise a server URL for upsert-equality: trim trailing slashes,
 * lowercase scheme + host, preserve the path's case. Dependency-free —
 * mirrors normalizeServerURL, never throws on odd input.
 */
export function normalizeServerUrl(raw: string): string {
  const s = raw.trim().replace(/\/+$/, '')
  let scheme = ''
  let rest = s
  const i = s.indexOf('://')
  if (i >= 0) {
    scheme = s.slice(0, i + 3).toLowerCase()
    rest = s.slice(i + 3)
  }
  const j = rest.indexOf('/')
  const host = j >= 0 ? rest.slice(0, j) : rest
  const path = j >= 0 ? rest.slice(j) : ''
  return scheme + host.toLowerCase() + path
}

function entryHasUrl(entry: ServerEntry, rawUrl: string | undefined): boolean {
  const key = normalizeServerUrl(rawUrl ?? '')
  if (key === '') return false
  if (normalizeServerUrl(entry.server) === key) return true
  return (entry.aliases ?? []).some((a) => normalizeServerUrl(a) === key)
}

/** InstanceID-first identity; URL/alias equality as the fallback (D4 shape). */
export function sameEntryIdentity(a: ServerEntry, b: ServerEntry): boolean {
  const aid = (a.instanceId ?? '').trim()
  const bid = (b.instanceId ?? '').trim()
  if (aid !== '' && bid !== '') return aid.toLowerCase() === bid.toLowerCase()
  return entryHasUrl(a, b.server) || entryHasUrl(b, a.server)
}

/**
 * Alias set for a re-connected instance: every previously-known hostname
 * EXCEPT the new primary, deduped by normalized form, order-stable (matched
 * entry's old primary first, then its prior aliases, then incoming ones).
 */
export function mergeAliases(
  primary: string,
  matched: ServerEntry,
  incoming: string[] | undefined,
): string[] {
  const seen = new Set<string>()
  const primaryKey = normalizeServerUrl(primary)
  if (primaryKey !== '') seen.add(primaryKey)
  const out: string[] = []
  const add = (raw: string) => {
    const k = normalizeServerUrl(raw)
    if (k === '' || seen.has(k)) return
    seen.add(k)
    out.push(raw)
  }
  add(matched.server)
  for (const a of matched.aliases ?? []) add(a)
  for (const a of incoming ?? []) add(a)
  return out
}

/**
 * Derive a short handle from a server URL (deriveName port): localhost family
 * → "local"; a bare IP verbatim; otherwise the first meaningful DNS label
 * with a leading "api"/"www" dropped. Uniqueness against `others` is by a
 * -2/-3… suffix (deriveUniqueName port, case-insensitive).
 */
export function deriveName(server: string): string {
  const host = hostOf(server)
  if (host === '') return 'server'
  const low = host.toLowerCase()
  if (low === 'localhost' || low === '127.0.0.1' || low === '::1' || low === '[::1]') {
    return 'local'
  }
  if (isIPv4(low)) {
    if (Number(low.split('.')[0]) === 127) return 'local'
    return low
  }
  const labels = low.split('.')
  let idx = 0
  if (labels.length > 1 && (labels[0] === 'api' || labels[0] === 'www')) idx = 1
  const label = labels[idx]
  return label !== undefined && label !== '' ? label : low
}

export function deriveUniqueName(server: string, others: ServerEntry[]): string {
  const taken = new Set(others.map((e) => displayName(e).toLowerCase()))
  const base = deriveName(server)
  if (!taken.has(base.toLowerCase())) return base
  for (let n = 2; ; n++) {
    const cand = `${base}-${n}`
    if (!taken.has(cand.toLowerCase())) return cand
  }
}

/** Explicit name verbatim, else derived from the URL. */
export function displayName(e: ServerEntry): string {
  const n = (e.name ?? '').trim()
  return n !== '' ? n : deriveName(e.server)
}

function hostOf(server: string): string {
  let rest = server.trim()
  const i = rest.indexOf('://')
  if (i >= 0) rest = rest.slice(i + 3)
  const j = rest.search(/[/?#]/)
  if (j >= 0) rest = rest.slice(0, j)
  const at = rest.lastIndexOf('@')
  if (at >= 0) rest = rest.slice(at + 1)
  // Strip a :port (but not an IPv6 colon).
  if (rest.startsWith('[')) {
    const close = rest.indexOf(']')
    return close >= 0 ? rest.slice(0, close + 1) : rest
  }
  const colon = rest.lastIndexOf(':')
  if (colon >= 0 && /^\d+$/.test(rest.slice(colon + 1))) rest = rest.slice(0, colon)
  return rest
}

function isIPv4(s: string): boolean {
  const parts = s.split('.')
  if (parts.length !== 4) return false
  return parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
}

/**
 * Upsert `entry` into the connect history AND promote it to the active flat
 * context (RememberServer port). Returns a NEW config — pure, deterministic.
 */
export function rememberServer(config: StoredConfig, entry: ServerEntry): StoredConfig {
  const next: ServerEntry = { ...entry }

  const kept: ServerEntry[] = []
  let matched: ServerEntry | undefined
  for (const e of config.knownServers ?? []) {
    if (matched === undefined && sameEntryIdentity(e, next)) {
      matched = e
      continue
    }
    kept.push(e)
  }

  if (matched !== undefined) {
    // A plain re-connect that didn't set a name/ID inherits what the matched
    // entry already carried, so nothing a prior connect learned is lost.
    if (!next.name) next.name = matched.name
    if ((next.instanceId ?? '').trim() === '') next.instanceId = matched.instanceId
    next.aliases = mergeAliases(next.server, matched, next.aliases)
  }

  if ((next.name ?? '').trim() === '') {
    next.name = deriveUniqueName(next.server, kept)
  }

  const knownServers = [next, ...kept].slice(0, MAX_KNOWN_SERVERS)

  // Promote to the active flat context — the last-location memory.
  return {
    ...config,
    knownServers,
    server: next.server,
    token: next.token,
    workspace: next.workspace !== undefined && next.workspace !== '' ? next.workspace : config.workspace,
    project: next.project !== undefined && next.project !== '' ? next.project : config.project,
    dataset: next.dataset !== undefined && next.dataset !== '' ? next.dataset : config.dataset,
  }
}
