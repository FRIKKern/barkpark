// This device's stable worker identity on the task board.
//
// The claim fence is per-WORKER, so the id must survive app restarts (a fresh
// id each launch would orphan our own claims and make every stamp read
// `not_holder`). Same shape as the other clients' defaults — the TUI uses
// `tui-<hostname>`, the cmux bridge `cmux-<surface-id>` — so a board reader can
// tell at a glance which surface holds a task.
import { getStorage } from '../state/storage'

const WORKER_KEY = 'tasks.worker_id'

function randomSuffix(): string {
  // 8 hex chars from Math.random — this is an identity label, not a secret;
  // collisions only matter across two installs claiming the same task, and
  // 2^32 is ample for a per-device tag.
  const a = Math.floor(Math.random() * 0x10000)
  const b = Math.floor(Math.random() * 0x10000)
  return (a.toString(16).padStart(4, '0') + b.toString(16).padStart(4, '0')).slice(0, 8)
}

/** Reads (minting once) this install's worker id. */
export function getWorkerId(): string {
  const store = getStorage()
  const existing = store.getString(WORKER_KEY)
  if (existing !== undefined && existing.trim() !== '') return existing
  const minted = `mobile-${randomSuffix()}`
  store.set(WORKER_KEY, minted)
  return minted
}
