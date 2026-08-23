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
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	tmp, err := os.CreateTemp(dir, cacheFileName(key)+".tmp-*")
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
	if err := os.Rename(tmpName, filepath.Join(dir, cacheFileName(key))); err != nil {
		os.Remove(tmpName)
	}
}
