package manifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Cache round-trips a fixture body + etag and salts admin vs anon into distinct
// slots.
func TestCacheRoundTrip(t *testing.T) {
	dir := t.TempDir()
	c := NewCache(dir)
	body := readFixture(t, "core-manifest.json")

	key := CacheKey("https://api.barkpark.cloud", "admin-token")
	if _, _, ok := c.Load(key); ok {
		t.Fatal("Load hit on an empty cache")
	}
	if err := c.Store(key, body, `W/"caps-admin-7f3a91c4"`); err != nil {
		t.Fatalf("Store: %v", err)
	}
	m, etag, ok := c.Load(key)
	if !ok {
		t.Fatal("Load miss after Store")
	}
	if etag != `W/"caps-admin-7f3a91c4"` {
		t.Errorf("etag = %q", etag)
	}
	if m.AuthTier != "admin" || len(m.Nouns) != 8 {
		t.Errorf("round-tripped manifest wrong: tier=%q nouns=%d", m.AuthTier, len(m.Nouns))
	}
}

// Different tokens against the same server land in different cache slots — an
// admin manifest must not be served to an anon caller.
func TestCacheKeySaltsByToken(t *testing.T) {
	base := "https://api.barkpark.cloud"
	admin := CacheKey(base, "admin-token")
	anon := CacheKey(base, "")
	other := CacheKey(base, "write-token")
	if admin == anon || admin == other || anon == other {
		t.Errorf("cache keys collide: admin=%q anon=%q other=%q", admin, anon, other)
	}
	// Same inputs must be stable.
	if CacheKey(base, "admin-token") != admin {
		t.Error("CacheKey not deterministic")
	}
}

// Store persists atomically: overwriting an existing key round-trips the new
// entry and leaves no stray temp files behind (the temp+rename intermediate is
// always cleaned up by the successful rename).
func TestCacheStoreOverwriteAtomic(t *testing.T) {
	dir := t.TempDir()
	c := NewCache(dir)
	body := readFixture(t, "core-manifest.json")
	key := CacheKey("https://api.barkpark.cloud", "admin-token")

	if err := c.Store(key, body, `W/"v1"`); err != nil {
		t.Fatalf("first Store: %v", err)
	}
	if err := c.Store(key, body, `W/"v2"`); err != nil {
		t.Fatalf("second Store: %v", err)
	}
	_, etag, ok := c.Load(key)
	if !ok {
		t.Fatal("Load miss after overwrite")
	}
	if etag != `W/"v2"` {
		t.Errorf("overwrite lost: etag = %q, want v2", etag)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "cache-") {
			t.Errorf("leftover temp file: %s", filepath.Join(dir, e.Name()))
		}
	}
}

// Store rejects a body that does not parse, so a later 304 cannot resurrect junk.
func TestCacheStoreRejectsBadBody(t *testing.T) {
	c := NewCache(t.TempDir())
	if err := c.Store("k", []byte(`{"not":"a manifest"}`), "e"); err == nil {
		t.Fatal("Store accepted a non-manifest body")
	}
}
