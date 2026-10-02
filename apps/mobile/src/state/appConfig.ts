// Persisted app config — the mobile sibling of the CLI's config.json: the
// Cloud session, the connect history (MRU), and the flat active context that
// IS the last-location memory (charter D14). One JSON blob under one key so
// a load/save round-trip is atomic at the MMKV layer.
import type { ServerEntry, StoredConfig } from '../cascade/knownServers'
import { rememberServer } from '../cascade/knownServers'
import { getCacheStore, instanceCacheKey } from './cache'
import { getSecretStore } from './secrets'
import { getStorage } from './storage'

const CONFIG_KEY = 'barkpark.config.v1'

// THE CREDENTIAL SPLIT (task-d524e210de241375). The MMKV blob is a plain file,
// so the two bearer tokens the app holds live in the SecretStore (Keychain /
// Keystore) and the blob carries only addresses, names and scope. Callers
// still see one StoredConfig — the split is invisible above this module.
// The MRU entries keep NO token at all: nothing reads one today (a server
// switch goes back through the Cloud cascade, which mints a fresh one), and
// twenty dormant tokens are twenty things to leak.
const CLOUD_TOKEN_KEY = 'barkpark.cloudToken'
const INSTANCE_TOKEN_KEY = 'barkpark.instanceToken'

function hasPlaintextToken(config: StoredConfig): boolean {
  return (
    config.cloudToken !== undefined ||
    config.token !== undefined ||
    (config.knownServers ?? []).some((e) => e.token !== undefined)
  )
}

/** The blob's shape: the config minus every token. */
function withoutTokens(config: StoredConfig): StoredConfig {
  const blob: StoredConfig = { ...config }
  delete blob.cloudToken
  delete blob.token
  if (blob.knownServers !== undefined) {
    blob.knownServers = blob.knownServers.map((entry) => {
      const kept = { ...entry }
      delete kept.token
      return kept
    })
  }
  return blob
}

function writeSecret(key: string, value: string | undefined): void {
  const secrets = getSecretStore()
  if ((value ?? '').trim() === '') secrets.delete(key)
  else secrets.set(key, value as string)
}

function readBlob(): StoredConfig {
  const raw = getStorage().getString(CONFIG_KEY)
  if (raw === undefined) return {}
  try {
    const parsed: unknown = JSON.parse(raw)
    if (typeof parsed === 'object' && parsed !== null) return parsed as StoredConfig
  } catch {
    // A corrupt blob must never brick the app (the CLI's BOM lesson) — fall
    // through to a clean slate; the next save self-heals.
  }
  return {}
}

export function loadConfig(): StoredConfig {
  let blob = readBlob()
  // Migration: an install from before the split holds its tokens in the
  // blob. Move them into the SecretStore and rewrite the blob clean — the
  // user stays signed in, and the plaintext copy is gone from this launch on.
  if (hasPlaintextToken(blob)) {
    saveConfig(blob)
    blob = withoutTokens(blob)
  }
  const config: StoredConfig = { ...blob }
  const secrets = getSecretStore()
  const cloudToken = secrets.get(CLOUD_TOKEN_KEY)
  const token = secrets.get(INSTANCE_TOKEN_KEY)
  if (cloudToken !== undefined) config.cloudToken = cloudToken
  if (token !== undefined) config.token = token
  return config
}

export function saveConfig(config: StoredConfig): void {
  // Secrets first: a sign-out (saveConfig({})) must drop the credentials even
  // if the blob write that follows were to fail.
  writeSecret(CLOUD_TOKEN_KEY, config.cloudToken)
  writeSecret(INSTANCE_TOKEN_KEY, config.token)
  getStorage().set(CONFIG_KEY, JSON.stringify(withoutTokens(config)))
}

/** Store the Cloud session (device-flow approval or paste-era login). */
export function saveCloudSession(session: { url: string; token: string; teamId: string }): StoredConfig {
  const next: StoredConfig = {
    ...loadConfig(),
    cloudUrl: session.url,
    cloudToken: session.token,
    cloudTeam: session.teamId,
  }
  saveConfig(next)
  return next
}

/**
 * THE D42 PER-INSTANCE CACHE CLEAR — the policy's call site.
 *
 * `CacheStore.clearInstance` (src/state/cache.ts) is the mechanism; this is
 * WHEN it fires: the two transitions that make a cached instance DEPART —
 * signing out and switching the active server. It lives here, in the two
 * functions that WRITE the active context, rather than in App.tsx's callbacks,
 * because those callbacks are one-liners over these writers: any future
 * sign-out or switch-server affordance inherits the clear instead of having to
 * remember it. (Both current triggers are proven end-to-end through a mounted
 * App in cacheClearWiring.test.tsx.)
 *
 * `arriving` present = a switch, so a plain RE-connect to the same instance
 * keeps its cache (a clear on every connect would make the cache pointless).
 * Comparison is on the normalized instance key, so casing/trailing-slash drift
 * is not a switch — and a genuine hostname change for the same instance IS
 * one, correctly: the cache is URL-keyed, so the old key's rows are
 * unreachable garbage from that moment on.
 *
 * Wrapped: a cache failure must never block a sign-out or a connect. The rows
 * it leaves behind are still bounded by the LRU cap and the schema wipe; a
 * user stranded in a signed-out-but-still-rendering shell would not be.
 */
function clearDepartingInstanceCache(departing: string | undefined, arriving?: string): void {
  const from = instanceCacheKey(departing ?? '')
  if (from === '') return // nothing was connected — nothing departs
  if (arriving !== undefined && instanceCacheKey(arriving) === from) return
  try {
    getCacheStore().clearInstance(from)
  } catch {
    // see above: never let the cache wedge a credential transition
  }
}

/** Upsert a connected server into the MRU + active context, persisted. */
export function rememberAndSave(entry: ServerEntry): StoredConfig {
  const prev = loadConfig()
  const next = rememberServer(prev, {
    ...entry,
    lastConnected: new Date().toISOString(),
  })
  saveConfig(next)
  // Server switch (D42): the instance we just left keeps no cached rows.
  clearDepartingInstanceCache(prev.server, next.server)
  return next
}

/** Update the active tenancy scope (workspace → project → dataset walk). */
export function saveActiveScope(scope: {
  workspace?: string
  project?: string
  dataset?: string
}): StoredConfig {
  const next = { ...loadConfig(), ...scope }
  saveConfig(next)
  return next
}

/**
 * Full sign-out: drop the Cloud session, the active connection, AND the
 * departing instance's cached rows (D42). The credentials go first — nothing,
 * including a broken cache, may leave a signed-out user signed in.
 */
export function clearConfig(): void {
  const departing = loadConfig().server
  saveConfig({})
  clearDepartingInstanceCache(departing)
}

export function hasCloudSession(config: StoredConfig): boolean {
  return (config.cloudToken ?? '').trim() !== ''
}

export function hasActiveServer(config: StoredConfig): boolean {
  return (config.server ?? '').trim() !== '' && (config.token ?? '').trim() !== ''
}
