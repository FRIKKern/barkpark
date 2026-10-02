// The native half of the SecretStore seam (task-d524e210de241375), driven
// through a fake expo-secure-store with the real module's contract: getItem
// answers string | null, deleteItemAsync is async. Pins the three things the
// device would otherwise be the only witness of: the device-only Keychain
// accessibility, a delete that the very next synchronous read honours, and
// the jest-expo auto-mock (answers undefined) being refused as "not a store".
import { getSecretStore, setSecretStoreForTesting } from '../src/state/secrets'

const mockItems = new Map<string, string>()
const mockCalls: { op: string; key: string; options: unknown }[] = []
let mockProbeAnswer: 'real' | 'mock' = 'real'

jest.mock('expo-secure-store', () => ({
  AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: 'AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY',
  getItem: (key: string, options: unknown) => {
    mockCalls.push({ op: 'get', key, options })
    if (mockProbeAnswer === 'mock') return undefined
    return mockItems.get(key) ?? null
  },
  setItem: (key: string, value: string, options: unknown) => {
    mockCalls.push({ op: 'set', key, options })
    mockItems.set(key, value)
  },
  deleteItemAsync: (key: string, options: unknown) => {
    mockCalls.push({ op: 'delete', key, options })
    // Resolves LATER — the cache must not wait for it.
    return new Promise<void>((resolve) => setTimeout(() => {
      mockItems.delete(key)
      resolve()
    }, 50))
  },
}))

beforeEach(() => {
  mockItems.clear()
  mockCalls.length = 0
  mockProbeAnswer = 'real'
  setSecretStoreForTesting(undefined)
})

describe('SecretStore over expo-secure-store', () => {
  it('writes and reads with device-only, after-first-unlock accessibility', () => {
    const store = getSecretStore()
    store.set('barkpark.cloudToken', 'tok')
    expect(mockItems.get('barkpark.cloudToken')).toBe('tok')
    setSecretStoreForTesting(undefined) // a fresh launch: no cache
    expect(getSecretStore().get('barkpark.cloudToken')).toBe('tok')
    for (const c of mockCalls) {
      expect(c.options).toEqual({ keychainAccessible: 'AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY' })
    }
  })

  it('a delete is visible to the next synchronous read, before the async delete lands', () => {
    const store = getSecretStore()
    store.set('barkpark.instanceToken', 'tok')
    store.delete('barkpark.instanceToken')
    expect(mockItems.has('barkpark.instanceToken')).toBe(true) // native delete still in flight
    expect(store.get('barkpark.instanceToken')).toBeUndefined()
  })

  it('a module that answers undefined (an auto-mock / missing native half) is refused, not trusted', () => {
    mockProbeAnswer = 'mock'
    const store = getSecretStore()
    store.set('k', 'v')
    // The in-memory twin took the write — nothing was "stored" into a void.
    expect(store.get('k')).toBe('v')
    expect(mockItems.has('k')).toBe(false)
  })
})
