// Persisted app config — the mobile sibling of the CLI's config.json: the
// Cloud session, the connect history (MRU), and the flat active context that
// IS the last-location memory (charter D14). One JSON blob under one key so
// a load/save round-trip is atomic at the MMKV layer.
import type { ServerEntry, StoredConfig } from '../cascade/knownServers'
import { rememberServer } from '../cascade/knownServers'
import { getStorage } from './storage'

const CONFIG_KEY = 'barkpark.config.v1'

export function loadConfig(): StoredConfig {
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

export function saveConfig(config: StoredConfig): void {
  getStorage().set(CONFIG_KEY, JSON.stringify(config))
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

/** Upsert a connected server into the MRU + active context, persisted. */
export function rememberAndSave(entry: ServerEntry): StoredConfig {
  const next = rememberServer(loadConfig(), {
    ...entry,
    lastConnected: new Date().toISOString(),
  })
  saveConfig(next)
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

/** Full sign-out: drop the Cloud session AND the active connection. */
export function clearConfig(): void {
  saveConfig({})
}

export function hasCloudSession(config: StoredConfig): boolean {
  return (config.cloudToken ?? '').trim() !== ''
}

export function hasActiveServer(config: StoredConfig): boolean {
  return (config.server ?? '').trim() !== '' && (config.token ?? '').trim() !== ''
}
