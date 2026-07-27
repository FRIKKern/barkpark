// Persisted config: storage round-trip on the in-memory seam (the same
// interface MMKV serves on-device), last-location memory, and the
// corrupt-blob self-heal (the CLI's BOM lesson, ported).
import {
  clearConfig,
  hasActiveServer,
  hasCloudSession,
  loadConfig,
  rememberAndSave,
  saveCloudSession,
  saveActiveScope,
} from '../src/state/appConfig'
import { getStorage, setStorageForTesting } from '../src/state/storage'

beforeEach(() => {
  setStorageForTesting(undefined)
})

describe('appConfig', () => {
  it('round-trips the cloud session and reports it', () => {
    expect(hasCloudSession(loadConfig())).toBe(false)
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: 'tok', teamId: 'team' })
    const config = loadConfig()
    expect(config.cloudToken).toBe('tok')
    expect(hasCloudSession(config)).toBe(true)
  })

  it('rememberAndSave persists the MRU head AND the flat active context (last location)', () => {
    saveCloudSession({ url: 'https://api.barkpark.cloud', token: 'tok', teamId: 'team' })
    rememberAndSave({ server: 'https://g.example', token: 'server-tok', name: 'g', dataset: 'production' })

    const config = loadConfig()
    expect(hasActiveServer(config)).toBe(true)
    expect(config.server).toBe('https://g.example')
    expect(config.dataset).toBe('production')
    expect(config.knownServers).toHaveLength(1)
    expect(config.knownServers![0]!.lastConnected).toBeDefined()
    // The cloud session survives a connect.
    expect(config.cloudToken).toBe('tok')
  })

  it('saveActiveScope walks the tenancy cascade without touching credentials', () => {
    rememberAndSave({ server: 'https://g.example', token: 't' })
    saveActiveScope({ workspace: 'acme', project: 'main', dataset: 'staging' })
    const config = loadConfig()
    expect(config.workspace).toBe('acme')
    expect(config.dataset).toBe('staging')
    expect(config.token).toBe('t')
  })

  it('a corrupt stored blob loads as a clean slate instead of bricking the app', () => {
    getStorage().set('barkpark.config.v1', '{not json')
    expect(loadConfig()).toEqual({})
  })

  it('clearConfig signs out completely', () => {
    saveCloudSession({ url: 'u', token: 't', teamId: 'x' })
    clearConfig()
    expect(hasCloudSession(loadConfig())).toBe(false)
  })
})
