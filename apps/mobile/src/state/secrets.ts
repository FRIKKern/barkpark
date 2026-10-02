// Secret persistence seam — the bearer tokens' home (task-d524e210de241375).
//
// The MMKV blob (src/state/storage.ts) is a PLAIN mmap file in the app
// sandbox: no encryptionKey, and on iOS it lives under a backed-up directory.
// Tokens therefore never go there. expo-secure-store is Keychain on iOS and
// Keystore-wrapped prefs on Android; its config plugin (app.json) also keeps
// the store out of Android Auto Backup.
//
// Accessibility is AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY: readable by a
// background wake once the phone has been unlocked since boot, and NEVER
// migrated to another device through a backup — a restored phone signs in
// again instead of inheriting a 30-day Cloud session.
//
// Same shape as storage.ts: the native require lives inside the try, so jest
// (and any binary built before the module was added) gets an in-memory twin
// instead of a red suite or a crash. That twin never touches disk: the cost
// of a stale binary is a sign-in per launch, never a token in a plain file.
//
// Deletes are async in expo-secure-store; the write-through cache below makes
// a delete visible to the very next synchronous read (a sign-out followed by
// loadConfig() must read "signed out", not the Keychain's pre-delete answer).

export interface SecretStore {
  get(key: string): string | undefined
  set(key: string, value: string): void
  delete(key: string): void
}

class MemorySecretStore implements SecretStore {
  private map = new Map<string, string>()

  get(key: string): string | undefined {
    return this.map.get(key)
  }

  set(key: string, value: string): void {
    this.map.set(key, value)
  }

  delete(key: string): void {
    this.map.delete(key)
  }
}

let store: SecretStore | undefined

function nativeStore(): SecretStore {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const SecureStore = require('expo-secure-store') as typeof import('expo-secure-store')
  const options = { keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY }
  // The probe: a module that resolves but whose native half is missing throws
  // here, inside the caller's try, instead of on the first real read. A real
  // store answers string | null; anything else (jest-expo's auto-mock answers
  // undefined and silently drops every write) is not a store.
  const probe: unknown = SecureStore.getItem('barkpark.probe', options)
  if (probe !== null && typeof probe !== 'string') {
    throw new Error('expo-secure-store is not backed by a native module')
  }
  const cache = new Map<string, string | null>()
  return {
    get(key) {
      if (cache.has(key)) return cache.get(key) ?? undefined
      let value: string | null = null
      try {
        value = SecureStore.getItem(key, options)
      } catch {
        // An unreadable item reads as absent (signed out), never a crash.
        value = null
      }
      cache.set(key, value)
      return value ?? undefined
    },
    set(key, value) {
      SecureStore.setItem(key, value, options)
      cache.set(key, value)
    },
    delete(key) {
      cache.set(key, null)
      SecureStore.deleteItemAsync(key, options).catch(() => {
        // Best effort; the cache already answers "absent" for this run.
      })
    },
  }
}

export function getSecretStore(): SecretStore {
  if (store !== undefined) return store
  try {
    store = nativeStore()
  } catch {
    store = new MemorySecretStore()
  }
  return store
}

/** Test seam: replace the secret backing (pass undefined to reset). */
export function setSecretStoreForTesting(next: SecretStore | undefined): void {
  store = next
}
