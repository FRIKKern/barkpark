package manifest

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Cache is an on-disk store for a fetched manifest body + its ETag, keyed by a
// caller-supplied string (see CacheKey). It backs the If-None-Match / 304 flow
// in Fetch: a 304 means "your cached body is current", so the cache must hold
// the body the ETag was minted for.
//
// Layout under Dir():
//
//	<dir>/<sha256(key)>.json   one entry: {"etag": "...", "body": <raw manifest>}
//
// The key is hashed into the filename so an arbitrary key (URL + token salt)
// produces a filesystem-safe, fixed-length name and the token never lands on
// disk in clear.
type Cache struct {
	dir string

	// ttl is the FRESH WINDOW: how long after a Store (or a Touch) an entry may
	// be served without contacting the server AT ALL. Zero — the NewCache
	// default — means "no fresh window": every Fetch revalidates with a
	// conditional GET, which is what this cache did before the window existed.
	// The window is opt-in via NewCacheWithTTL precisely so every existing
	// caller and test keeps the exact revalidate-always behaviour it was
	// written against, and only the CLI load path (internal/cli/load.go) buys
	// the request reduction the window exists for.
	ttl time.Duration
}

// cacheEntry is the on-disk JSON shape. Body is stored raw so a load returns the
// exact bytes the ETag was content-addressed over.
//
// ManifestVersion and GeneratedAt mirror the two generation fields the stored
// manifest itself carries (Manifest.ManifestVersion / Manifest.GeneratedAt in
// manifest.go), lifted to the entry's top level so Fetch's downgrade guard
// (fetch.go) can read the cached generation via CachedGeneration without a
// full re-parse of Body. Both are omitempty: a cacheEntry written before this
// guard existed (the pre-change shape, just {etag, body}) has neither.
// CachedGeneration reports that absence as ok=false — "generation unknown",
// never "definitely older" — so an old on-disk cache file degrades
// gracefully instead of blocking the next Store.
type cacheEntry struct {
	ETag            string          `json:"etag"`
	Body            json.RawMessage `json:"body"`
	ManifestVersion string          `json:"manifest_version,omitempty"`
	GeneratedAt     string          `json:"generated_at,omitempty"`

	// StoredAt is when THIS CLIENT last confirmed the entry current — set by
	// Store on a 200 and refreshed by Touch on a 304. It is deliberately not
	// GeneratedAt: GeneratedAt is the SERVER's build stamp and answers "which
	// manifest is this", while StoredAt answers "how long ago did we last ask",
	// which is the only question a TTL can be decided on. omitempty: an entry
	// written by a bp that predates the fresh window has none, and LoadFresh
	// reports that as NOT fresh, so a legacy cache file revalidates exactly as
	// it always did rather than being served blind for a window it never
	// consented to.
	StoredAt string `json:"stored_at,omitempty"`
}

// DefaultCacheDir is ${XDG_CACHE_HOME:-~/.cache}/barkpark. A missing HOME (rare,
// e.g. some CI) degrades to a relative ".cache/barkpark" rather than erroring —
// the cache is an optimisation, not a correctness dependency.
func DefaultCacheDir() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		if home, err := os.UserHomeDir(); err == nil {
			base = filepath.Join(home, ".cache")
		} else {
			base = ".cache"
		}
	}
	return filepath.Join(base, "barkpark")
}

// DefaultManifestTTL is the fresh window the CLI load path uses.
//
// SIXTY SECONDS, and the number is argued, not picked. The census on this row
// measured GET /v1/capabilities at 166,039 requests over 5.04 days — 32% of
// everything guerrilla served — because every `bp` invocation revalidated. A
// 60s window bounds that to AT MOST one capabilities request per minute per
// (box, server, credential), however many commands run in that minute; an
// agent fleet firing a command every second drops from ~60 requests/minute to
// 1, a ~98% cut on the hottest route on the box.
//
// It is short on purpose. The cost of the window is a STALE COMMAND TREE, and
// a stale tree is worse than a slow one: it makes bp offer verbs the server
// dropped and hide verbs the server added, which reads to an agent as "nothing
// found" rather than as staleness. One minute is inside the time it takes a
// human or an agent to notice and re-run, and `--no-cache` is the escape hatch
// that skips the window entirely (see internal/cli/load.go).
const DefaultManifestTTL = 60 * time.Second

// NewCache returns a Cache rooted at dir with NO fresh window (ttl 0): every
// Fetch revalidates with a conditional GET. An empty dir falls back to
// DefaultCacheDir. Use NewCacheWithTTL to buy the fresh window.
func NewCache(dir string) *Cache {
	return NewCacheWithTTL(dir, 0)
}

// NewCacheWithTTL returns a Cache rooted at dir whose entries may be served
// without any request for ttl after the last Store/Touch. A ttl <= 0 disables
// the window (identical to NewCache).
func NewCacheWithTTL(dir string, ttl time.Duration) *Cache {
	if dir == "" {
		dir = DefaultCacheDir()
	}
	if ttl < 0 {
		ttl = 0
	}
	return &Cache{dir: dir, ttl: ttl}
}

// TTL returns the fresh window (0 when there is none).
func (c *Cache) TTL() time.Duration { return c.ttl }

// Dir returns the cache root directory.
func (c *Cache) Dir() string { return c.dir }

// CacheKey builds the (server base_url + token-tier salt) cache key. The token
// is hashed, not embedded — two tokens that resolve to different server tiers
// land in different cache slots (an admin manifest and an anon manifest differ),
// while the token itself never appears in the key or the filename. An empty
// token (anonymous caller) salts to a stable "anon" bucket.
func CacheKey(baseURL, token string) string {
	salt := "anon"
	if token != "" {
		sum := sha256.Sum256([]byte(token))
		salt = fmt.Sprintf("%x", sum[:8])
	}
	return baseURL + "|" + salt
}

func (c *Cache) pathFor(key string) string {
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(c.dir, fmt.Sprintf("%x.json", sum))
}

// loadEntry reads and decodes the on-disk entry for key. ok=false covers every
// miss shape — no file, unreadable, not JSON — because a cache miss is normal
// control flow, never an error.
func (c *Cache) loadEntry(key string) (cacheEntry, bool) {
	var entry cacheEntry
	raw, err := os.ReadFile(c.pathFor(key))
	if err != nil {
		return cacheEntry{}, false
	}
	if err := json.Unmarshal(raw, &entry); err != nil {
		return cacheEntry{}, false
	}
	return entry, true
}

// LoadFresh returns the cached manifest when the entry for key is INSIDE the
// fresh window — i.e. this client confirmed it current less than c.ttl ago. A
// true here means Fetch may skip the network entirely: no request at all, not
// even a conditional one. It is the whole point of this change.
//
// ok=false — revalidate — on every uncertainty:
//   - no fresh window configured (ttl <= 0),
//   - no entry, a corrupt entry, or a body that no longer parses,
//   - no stored_at (an entry written by a bp that predates the window),
//   - an unparseable stored_at,
//   - an age >= ttl,
//   - a NEGATIVE age, i.e. a stored_at in the future. That is a clock that
//     moved backwards (or a copied cache dir), and honouring it would pin a
//     manifest as "fresh" for however far ahead the stamp sits. Revalidating
//     costs one conditional GET; trusting it costs an unbounded stale window.
func (c *Cache) LoadFresh(key string) (m *Manifest, ok bool) {
	if c.ttl <= 0 {
		return nil, false
	}
	entry, ok := c.loadEntry(key)
	if !ok || entry.StoredAt == "" {
		return nil, false
	}
	storedAt, err := time.Parse(time.RFC3339Nano, entry.StoredAt)
	if err != nil {
		return nil, false
	}
	age := time.Since(storedAt)
	if age < 0 || age >= c.ttl {
		return nil, false
	}
	parsed, err := Parse(entry.Body)
	if err != nil {
		return nil, false
	}
	return parsed, true
}

// Touch re-stamps stored_at on the existing entry for key, leaving the body and
// the ETag untouched. Fetch calls it on a 304: the server just CONFIRMED the
// cached body is current, so the fresh window legitimately restarts from now.
// Without it a cache entry would revalidate on every invocation forever after
// its first window expired, and the request count would be bounded by nothing.
// A missing entry is a no-op (nil): there is nothing to touch, and inventing an
// entry with no body would be a lie the next 304 would trust.
func (c *Cache) Touch(key string) error {
	entry, ok := c.loadEntry(key)
	if !ok {
		return nil
	}
	entry.StoredAt = time.Now().UTC().Format(time.RFC3339Nano)
	return c.writeEntry(key, entry)
}

// Load returns the cached manifest, its ETag, and ok=true when an entry for key
// exists and parses. A missing/corrupt entry returns ok=false (never an error —
// a cache miss is normal control flow).
func (c *Cache) Load(key string) (m *Manifest, etag string, ok bool) {
	entry, ok := c.loadEntry(key)
	if !ok {
		return nil, "", false
	}
	parsed, err := Parse(entry.Body)
	if err != nil {
		return nil, "", false
	}
	return parsed, entry.ETag, true
}

// CachedGeneration returns the generated_at and manifest_version Store last
// recorded for key, read directly off the entry's top-level fields (no Body
// re-parse). ok=false means either no entry exists for key, the entry is
// corrupt, or the entry predates this guard (Store began stamping these
// fields with this change — an on-disk entry from an older bp has neither).
// Callers MUST treat ok=false as "generation unknown," never as "older," so
// a legacy cache file never blocks the next Store.
func (c *Cache) CachedGeneration(key string) (generatedAt, manifestVersion string, ok bool) {
	entry, ok := c.loadEntry(key)
	if !ok {
		return "", "", false
	}
	if entry.GeneratedAt == "" {
		return "", "", false
	}
	return entry.GeneratedAt, entry.ManifestVersion, true
}

// Store writes body + etag for key, creating the cache dir if needed. It
// validates body parses before persisting so a 304 against this entry later
// always returns a usable manifest. A write failure is returned so the caller
// can decide whether to care (Fetch ignores it — caching is best-effort).
func (c *Cache) Store(key string, body []byte, etag string) error {
	m, err := Parse(body)
	if err != nil {
		return fmt.Errorf("cache store: body does not parse: %w", err)
	}
	entry := cacheEntry{
		ETag:            etag,
		Body:            json.RawMessage(body),
		ManifestVersion: m.ManifestVersion,
		GeneratedAt:     m.GeneratedAt,
		StoredAt:        time.Now().UTC().Format(time.RFC3339Nano),
	}
	return c.writeEntry(key, entry)
}

// writeEntry persists entry for key. Split out of Store so Touch re-stamps
// stored_at through the SAME atomic rename — a torn cache file from a touch
// would be exactly as fatal as one from a store.
func (c *Cache) writeEntry(key string, entry cacheEntry) error {
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return fmt.Errorf("cache store: mkdir: %w", err)
	}
	data, err := json.Marshal(entry)
	if err != nil {
		return fmt.Errorf("cache store: marshal: %w", err)
	}
	// Write to a temp file in the same dir (same filesystem → atomic rename), then
	// rename over the target. A crash, disk-full, or concurrent bp can't observe a
	// truncated or interleaved cache file — the reader sees either the old file or
	// the new one, never a half-written one. CreateTemp defaults to 0600; Chmod
	// restores the 0644 intent so other tools sharing the cache dir can read it.
	tmp, err := os.CreateTemp(c.dir, "cache-*.json")
	if err != nil {
		return fmt.Errorf("cache store: create temp in %s: %w", c.dir, err)
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("cache store: write temp %s: %w", tmp.Name(), err)
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("cache store: chmod temp %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("cache store: close temp %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), c.pathFor(key)); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("cache store: rename %s: %w", c.pathFor(key), err)
	}
	return nil
}
