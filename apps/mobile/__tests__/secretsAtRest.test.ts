// Credentials at rest (task-d524e210de241375). The MMKV config blob is a
// PLAIN file in the app sandbox — no encryptionKey, and on iOS it sits in a
// backed-up directory — so no bearer token may ever reach it. The Cloud
// session token and the active instance token live behind the SecretStore
// seam (expo-secure-store: Keychain / Keystore on device; an in-memory twin
// under jest), and the MRU keeps only addresses.
//
// The probe records EVERY byte written to the KeyValueStorage seam (the MMKV
// stand-in) and greps it for the token strings — which is exactly what an
// attacker with a backup or a rooted file read would do.
import {
  clearConfig,
  hasActiveServer,
  hasCloudSession,
  loadConfig,
  rememberAndSave,
  saveActiveScope,
  saveCloudSession,
  saveConfig,
} from '../src/state/appConfig'
import { getSecretStore, setSecretStoreForTesting, type SecretStore } from '../src/state/secrets'
import { setStorageForTesting, type KeyValueStorage } from '../src/state/storage'

const CLOUD_TOK = 'bpc_cloud_SECRET_aaaa'
const SERVER_TOK = 'bp_app_SECRET_bbbb'
const OTHER_TOK = 'bp_app_SECRET_cccc'
const CONFIG_KEY = 'barkpark.config.v1'

class RecordingStorage implements KeyValueStorage {
  readonly map = new Map<string, string>()
  readonly writes: string[] = []
  getString(key: string): string | undefined {
    return this.map.get(key)
  }
  set(key: string, value: string): void {
    this.writes.push(value)
    this.map.set(key, value)
  }
  delete(key: string): void {
    this.map.delete(key)
  }
}

/** A durable SecretStore with switchable failure modes (the device's
 * Keychain/Keystore stand-in). */
class FakeKeychain implements SecretStore {
  durable = true
  failWrites = false
  corruptWrites = false
  readonly map = new Map<string, string>()
  get(key: string): string | undefined {
    return this.map.get(key)
  }
  set(key: string, value: string): void {
    if (this.failWrites) throw new Error('keychain write refused')
    this.map.set(key, this.corruptWrites ? `${value}-garbled` : value)
  }
  delete(key: string): void {
    this.map.delete(key)
  }
}

let disk: RecordingStorage
let keychain: FakeKeychain

beforeEach(() => {
  setStorageForTesting(undefined) // also resets the secret store
  disk = new RecordingStorage()
  setStorageForTesting(disk)
  keychain = new FakeKeychain()
  setSecretStoreForTesting(keychain)
})

function everythingOnDisk(): string {
  return [...disk.writes, ...disk.map.values()].join('\n')
}

describe('credentials never reach the plaintext MMKV blob', () => {
  it('the cloud session token stays out of MMKV but still loads', () => {
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: CLOUD_TOK, teamId: 'team' })
    expect(everythingOnDisk()).not.toContain(CLOUD_TOK)
    const config = loadConfig()
    expect(config.cloudToken).toBe(CLOUD_TOK)
    expect(config.cloudUrl).toBe('https://api.barkpark.cloud')
    expect(hasCloudSession(config)).toBe(true)
  })

  it('the instance token stays out of MMKV — the active context AND the MRU entry', () => {
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: CLOUD_TOK, teamId: 'team' })
    rememberAndSave({ server: 'https://g.example', token: SERVER_TOK, name: 'g', dataset: 'production' })
    saveActiveScope({ workspace: 'acme', project: 'main', dataset: 'staging' })
    rememberAndSave({ server: 'https://h.example', token: OTHER_TOK, name: 'h' })

    const onDisk = everythingOnDisk()
    expect(onDisk).not.toContain(CLOUD_TOK)
    expect(onDisk).not.toContain(SERVER_TOK)
    expect(onDisk).not.toContain(OTHER_TOK)

    const config = loadConfig()
    expect(config.server).toBe('https://h.example')
    expect(config.token).toBe(OTHER_TOK)
    expect(hasActiveServer(config)).toBe(true)
    expect(config.knownServers?.map((e) => e.server)).toEqual(['https://h.example', 'https://g.example'])
    for (const entry of config.knownServers ?? []) expect(entry.token).toBeUndefined()
  })

  it('a pre-fix install migrates: tokens move into the secret store, the blob is rewritten clean', () => {
    disk.set(
      CONFIG_KEY,
      JSON.stringify({
        cloudUrl: 'https://api.barkpark.cloud',
        cloudToken: CLOUD_TOK,
        server: 'https://g.example',
        token: SERVER_TOK,
        knownServers: [{ server: 'https://g.example', token: SERVER_TOK, name: 'g' }],
      }),
    )

    const config = loadConfig()
    // No forced re-login: the session and the connection both survive.
    expect(config.cloudToken).toBe(CLOUD_TOK)
    expect(config.token).toBe(SERVER_TOK)
    expect(hasActiveServer(config)).toBe(true)
    // ...and the plaintext copy is gone from the blob now on disk.
    const blob = disk.getString(CONFIG_KEY) ?? ''
    expect(blob).not.toContain(CLOUD_TOK)
    expect(blob).not.toContain(SERVER_TOK)
    expect(JSON.parse(blob).server).toBe('https://g.example')
    expect(getSecretStore().get('barkpark.cloudToken')).toBe(CLOUD_TOK)
  })

  it('sign-out deletes the secrets, not just the blob', () => {
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: CLOUD_TOK, teamId: 'team' })
    rememberAndSave({ server: 'https://g.example', token: SERVER_TOK })
    clearConfig()
    expect(loadConfig()).toEqual({})
    expect(getSecretStore().get('barkpark.cloudToken')).toBeUndefined()
    expect(getSecretStore().get('barkpark.instanceToken')).toBeUndefined()
  })

  it('migration write failure: the MMKV copy is kept, the user stays signed in, the next launch retries', () => {
    const legacy = {
      cloudUrl: 'https://api.barkpark.cloud',
      cloudToken: CLOUD_TOK,
      server: 'https://g.example',
      token: SERVER_TOK,
    }
    disk.set(CONFIG_KEY, JSON.stringify(legacy))
    keychain.failWrites = true

    const config = loadConfig()
    expect(config.cloudToken).toBe(CLOUD_TOK)
    expect(config.token).toBe(SERVER_TOK)
    expect(disk.getString(CONFIG_KEY)).toContain(CLOUD_TOK) // not deleted
    expect(disk.getString(CONFIG_KEY)).toContain(SERVER_TOK)

    // Next launch, the Keychain works again: the move completes.
    keychain.failWrites = false
    const retried = loadConfig()
    expect(retried.cloudToken).toBe(CLOUD_TOK)
    expect(retried.token).toBe(SERVER_TOK)
    expect(disk.getString(CONFIG_KEY)).not.toContain(CLOUD_TOK)
    expect(keychain.map.get('barkpark.instanceToken')).toBe(SERVER_TOK)
  })

  it('migration read-back mismatch: the MMKV copy is kept and the real token still loads', () => {
    disk.set(CONFIG_KEY, JSON.stringify({ cloudUrl: 'https://api.barkpark.cloud', cloudToken: CLOUD_TOK }))
    keychain.corruptWrites = true

    expect(loadConfig().cloudToken).toBe(CLOUD_TOK) // never the garbled read-back
    expect(disk.getString(CONFIG_KEY)).toContain(CLOUD_TOK)
  })

  it('a failed save keeps the token in MMKV rather than dropping it (no logout)', () => {
    keychain.failWrites = true
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: CLOUD_TOK, teamId: 'team' })
    expect(loadConfig().cloudToken).toBe(CLOUD_TOK)
  })

  it('a binary without the native module (non-durable store) keeps the pre-fix blob behaviour', () => {
    setSecretStoreForTesting(undefined) // jest default: the in-memory, non-durable twin
    expect(getSecretStore().durable).toBe(false)
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: CLOUD_TOK, teamId: 'team' })
    expect(disk.getString(CONFIG_KEY)).toContain(CLOUD_TOK)
    expect(loadConfig().cloudToken).toBe(CLOUD_TOK)
  })

  it('saveConfig with an empty token clears the stored one', () => {
    saveConfig({ server: 'https://g.example', token: SERVER_TOK })
    saveConfig({ server: 'https://g.example' })
    expect(loadConfig().token).toBeUndefined()
  })
})
