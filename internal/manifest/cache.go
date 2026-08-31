package manifest

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
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

// NewCache returns a Cache rooted at dir. An empty dir falls back to
// DefaultCacheDir.
func NewCache(dir string) *Cache {
	if dir == "" {
		dir = DefaultCacheDir()
	}
	return &Cache{dir: dir}
}

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

// Load returns the cached manifest, its ETag, and ok=true when an entry for key
// exists and parses. A missing/corrupt entry returns ok=false (never an error —
// a cache miss is normal control flow).
func (c *Cache) Load(key string) (m *Manifest, etag string, ok bool) {
	raw, err := os.ReadFile(c.pathFor(key))
	if err != nil {
		return nil, "", false
	}
	var entry cacheEntry
	if err := json.Unmarshal(raw, &entry); err != nil {
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
	raw, err := os.ReadFile(c.pathFor(key))
	if err != nil {
		return "", "", false
	}
	var entry cacheEntry
	if err := json.Unmarshal(raw, &entry); err != nil {
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
	if err := os.MkdirAll(c.dir, 0o755); err != nil {
		return fmt.Errorf("cache store: mkdir: %w", err)
	}
	entry := cacheEntry{
		ETag:            etag,
		Body:            json.RawMessage(body),
		ManifestVersion: m.ManifestVersion,
		GeneratedAt:     m.GeneratedAt,
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
