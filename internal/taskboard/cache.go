package taskboard

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
)

// cache.go is the first-paint snapshot cache: a best-effort on-disk copy of the
// last board a scope saw, so `bp tasks` paints real rows instantly on the next
// launch instead of a blank screen while the first fetch is in flight (charter
// decision #9 — "never a blank screen"). It is PURE file I/O keyed by scope
// identity: no tea, no network, no clock, so it round-trips under a t.TempDir().
//
// Two hard contracts keep the cache an optimization and never a liability:
//
//   - LOAD is tolerant: any read or parse failure is a MISS (zero, false), never
//     an error surface. A corrupt or partial cache degrades to the honest
//     "syncing…" first paint — it can never crash or block the pane.
//   - SAVE is best-effort: every failure (marshal, mkdir, temp, write, rename) is
//     swallowed. Persisting the board must never interrupt the live loop; a
//     read-only home just means the next start pays the first-fetch cost.
//
// A cache load NEVER stamps the board as live and NEVER seeds a change-highlight
// baseline — see primeFromCache (program.go) for the honest-staleness and
// decision-20 flash contracts that ride on these functions.

// cacheFilePrefix namespaces the cache files inside the shared bp config dir so
// they can never collide with config.json (or each other, across scopes).
const cacheFilePrefix = "taskboard-cache-"

// cacheKey derives a short, filesystem-safe identity for a board's scope from
// its server + workspace + project + dataset. It is the sha256 hex prefix of the
// joined identity: stable across runs for the same scope, distinct across scopes,
// and safe as a filename component (no slashes or host characters leak through).
// A NUL separator between the parts stops "ab"+""+"c" from hashing the same as
// "a"+"b"+"c" — distinct scopes must never share a cache file.
//
// Dataset joins the key (charter wave-22 D125): the /v1/tasks reads are
// dataset-flat, so two datasets on the same server/workspace/project see the
// same corpus and a shared cache is not a correctness bug — but folding it in is
// cheap future-proofing (one one-time cold paint per new scope) that keeps the
// key aligned with the rest of the scope tuple the board threads (Config.Dataset
// already scopes the live listener), so a later dataset-scoped read can never
// silently reuse another dataset's first-paint cache.
func cacheKey(server, workspace, project, dataset string) string {
	sum := sha256.Sum256([]byte(server + "\x00" + workspace + "\x00" + project + "\x00" + dataset))
	return hex.EncodeToString(sum[:])[:16]
}

// legacyCacheKey is the pre-dataset cache identity. Keep it only as a read
// fallback so upgrades do not turn a perfectly good cached board into a blank
// cold start. A successful fallback is immediately migrated to cacheKey by
// primeFromCache; every subsequent write remains dataset-scoped.
func legacyCacheKey(server, workspace, project string) string {
	sum := sha256.Sum256([]byte(server + "\x00" + workspace + "\x00" + project))
	return hex.EncodeToString(sum[:])[:16]
}

// cacheFileName is the on-disk file name for a scope key.
func cacheFileName(key string) string { return cacheFilePrefix + key + ".json" }

// LoadCachedSnapshot reads the first-paint snapshot for key from dir. It is
// TOLERANT by contract: an empty dir, a missing file, an unreadable file, or any
// JSON parse error all return (zero Snapshot, false) — never an error. The cache
// is an optimization, not a correctness dependency, so a bad cache simply misses
// and the pane falls back to its honest cold-start paint.
func LoadCachedSnapshot(dir, key string) (Snapshot, bool) {
	if dir == "" {
		return Snapshot{}, false
	}
	raw, err := os.ReadFile(filepath.Join(dir, cacheFileName(key)))
	if err != nil {
		return Snapshot{}, false
	}
	var s Snapshot
	if err := json.Unmarshal(raw, &s); err != nil {
		return Snapshot{}, false
	}
	return s, true
}

// SaveCachedSnapshot persists s as the first-paint cache for key under dir. It
// is BEST-EFFORT by contract: every failure is swallowed silently, because
// persisting the board must never interrupt the live board.
//
// The write is ATOMIC: marshal to a uniquely-named temp file in the SAME dir
// (same filesystem → rename is atomic), then rename over the target. A reader —
// this process next launch, or a concurrent bp — never observes a half-written
// file, and a crash mid-write leaves the previous cache intact rather than a
// truncated one. On any failure the temp file is removed so no droppings are
// left behind next to the real cache.
func SaveCachedSnapshot(dir, key string, s Snapshot) {
	if dir == "" {
		return
	}
	raw, err := json.Marshal(s)
	if err != nil {
		return
	}
	writeFileAtomic(dir, cacheFileName(key), raw)
}

// writeFileAtomic is the shared best-effort atomic write behind both save paths:
// marshal into a uniquely-named temp file in the SAME dir (same filesystem →
// rename is atomic), then rename over the target, removing the temp on any
// failure so no droppings are left next to the real file. Every error is
// swallowed: persisting is an optimization and must never interrupt the board.
func writeFileAtomic(dir, name string, raw []byte) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, name+".tmp-*")
	if err != nil {
		return
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return
	}
	if err := os.Rename(tmpName, filepath.Join(dir, name)); err != nil {
		os.Remove(tmpName)
	}
}

// --- the keyset cursor's own file --------------------------------------------
//
// The resume cursor used to live ONLY inside the snapshot cache (Snapshot.
// EventCursor), which is written from exactly one place: applySnapshot, after a
// re-list lands (live.go). The catch-up loop deliberately does NOT re-list —
// that is the whole point of the seek/drain path — so a board that walked the
// feed to the tip and then quit persisted nothing, and the next launch started
// the catch-up from wherever the last re-list happened to leave it. Measured on
// this machine 2026-09-09: three of four taskboard-cache-*.json files carried no
// event_cursor at all and the fourth was 637 pages behind the live tip.
//
// So the cursor gets its OWN file, next to the snapshot cache and keyed the same
// way. Two reasons it is a separate file rather than a rewrite of the snapshot:
//
//   - COST. The snapshot is the heavy pair's output (~70 KB of board). Re-
//     marshalling it on every cursor advance to change one integer is the write
//     amplification the poll loop exists to avoid; the cursor file is ~30 bytes.
//   - HONESTY. primeFromCache paints whatever Snapshot it loads. A board that
//     has never re-listed has no snapshot to write, and writing a task-less one
//     just to carry a cursor would turn the next launch's honest "syncing…" cold
//     paint into an empty board. The cursor must not be hostage to the board,
//     and the board must not be forged to carry the cursor.
//
// Both functions keep cache.go's contracts: LOAD is tolerant (any failure is a
// miss), SAVE is best-effort (every failure swallowed). A lost cursor costs one
// catch-up walk, never a wrong row — the cursor carries no truth (decision #4).

// cursorFilePrefix namespaces the cursor files inside the shared bp config dir.
const cursorFilePrefix = "taskboard-cursor-"

// cursorFileName is the on-disk file name for a scope key's resume cursor.
func cursorFileName(key string) string { return cursorFilePrefix + key + ".json" }

// cachedCursor is the cursor file's shape. A struct, not a bare integer, so a
// later field (a stamp, a feed identity) can join it without a format break.
type cachedCursor struct {
	EventCursor int64 `json:"event_cursor"`
}

// LoadCachedEventCursor reads the persisted keyset resume cursor for key from
// dir. TOLERANT by contract: empty dir, missing file, unreadable file, parse
// error, or a non-positive value all report (0, false) — the caller then starts
// at 0 and pays one catch-up.
func LoadCachedEventCursor(dir, key string) (int64, bool) {
	if dir == "" {
		return 0, false
	}
	raw, err := os.ReadFile(filepath.Join(dir, cursorFileName(key)))
	if err != nil {
		return 0, false
	}
	var c cachedCursor
	if err := json.Unmarshal(raw, &c); err != nil {
		return 0, false
	}
	if c.EventCursor <= 0 {
		return 0, false
	}
	return c.EventCursor, true
}

// SaveCachedEventCursor persists cursor as the resume point for key under dir.
// BEST-EFFORT and ATOMIC, exactly like SaveCachedSnapshot: temp file in the same
// dir, then rename, and every failure is swallowed so the live loop is never
// interrupted by a read-only home.
//
// A non-positive cursor is not written: 0 means "no resume point", and the
// absence of the file says that already.
func SaveCachedEventCursor(dir, key string, cursor int64) {
	if dir == "" || cursor <= 0 {
		return
	}
	raw, err := json.Marshal(cachedCursor{EventCursor: cursor})
	if err != nil {
		return
	}
	writeFileAtomic(dir, cursorFileName(key), raw)
}
