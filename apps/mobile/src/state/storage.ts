// Key-value persistence seam. MMKV v4 is the real backing store (charter
// D14 cache seam: MMKV for config/MRU); it is a NATIVE module, so under jest
// (and Expo Go without a dev build) construction throws — the in-memory
// fallback keeps every consumer honest about the same interface instead of
// sprinkling try/catch at call sites. Swapping the seam also keeps the
// expo-sqlite row cache (wired in TasksScreen's future) symmetrical.

export interface KeyValueStorage {
  getString(key: string): string | undefined
  set(key: string, value: string): void
  delete(key: string): void
}

class MemoryStorage implements KeyValueStorage {
  private map = new Map<string, string>()

  getString(key: string): string | undefined {
    return this.map.get(key)
  }

  set(key: string, value: string): void {
    this.map.set(key, value)
  }

  delete(key: string): void {
    this.map.delete(key)
  }
}

let storage: KeyValueStorage | undefined

export function getStorage(): KeyValueStorage {
  if (storage !== undefined) return storage
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const { createMMKV } = require('react-native-mmkv') as typeof import('react-native-mmkv')
    const mmkv = createMMKV({ id: 'barkpark' })
    storage = {
      getString: (key) => mmkv.getString(key),
      set: (key, value) => mmkv.set(key, value),
      delete: (key) => {
        mmkv.remove(key)
      },
    }
  } catch {
    storage = new MemoryStorage()
  }
  return storage
}

/** Test seam: replace the storage backing (pass undefined to reset). */
export function setStorageForTesting(next: KeyValueStorage | undefined): void {
  storage = next
}
