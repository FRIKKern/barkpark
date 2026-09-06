package manifest

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// downgradeManifest builds a minimal, valid manifest body with the given
// generated_at/etag — the two fields this guard cares about.
func downgradeManifest(generatedAt, etag string) string {
	return `{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"` + generatedAt + `","etag":"` + etag + `","nouns":[],"commands":[]}`
}

// captureStderr redirects os.Stderr for the duration of fn and returns
// whatever was written to it.
//
// The pipe is drained by a goroutine started BEFORE fn runs, and that ordering
// is the whole point. A pipe write that fills the kernel buffer blocks the
// writer until a reader takes bytes out, and on darwin a fresh pipe's buffer is
// 512 bytes (Linux gives 64 KiB, which is why CI never saw this). The code
// under test here writes more than that in one call: apiclient's retry notifier
// prints a line per attempt on a transient 500, and warnServingCachedManifest
// then adds a 179-byte notice. Reading only after fn returned meant nothing
// drained the pipe while those writes happened, so
// TestFetchServesCachedManifestOnServerFaultAndTransportError/500 blocked
// forever inside Fetch and the package ended in `panic: test timed out`.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stderr = w

	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(r)
		done <- buf.String()
	}()

	// Restore and close inside a defer so a t.Fatalf (runtime.Goexit) inside fn
	// still releases the reader instead of leaking a blocked goroutine.
	func() {
		defer func() {
			os.Stderr = old
			_ = w.Close()
		}()
		fn()
	}()

	out := <-done
	_ = r.Close()
	return out
}

// DECISION RECORD (acceptance criterion #2): on a detected downgrade, Fetch
// KEEPS the cached manifest and returns it with a nil error, rather than
// failing the call. Rationale: this guard cannot distinguish clock skew
// (the case it actually catches) from anything scarier, and a hard refusal
// would make bp unusable against a correctly-clocked replica for as long as
// some other box's clock is skewed fast — a new failure mode worse than the
// one being guarded against. A stale-but-plausible cached answer is strictly
// better than no answer. The older body must never overwrite the cache
// either way (see the assertions below) so a subsequent equal-or-newer fetch
// heals the situation with zero manual cache surgery.
//
// This test fails on today's main: fetch.go's StatusOK branch unconditionally
// Parses and Store()s any 200 body with no comparison against the cached
// generation, so the second Fetch below would return (m, nil) with
// GeneratedAt "2026-05-01T00:00:00Z" — the older, incoming generation —
// instead of the cached "2026-06-01T00:00:00Z", and would overwrite the
// on-disk cache entry with the older body.
func TestFetchKeepsCachedManifestOnGeneratedAtDowngrade(t *testing.T) {
	var body string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Always answer 200 (never 304) so both calls exercise the StatusOK
		// branch under test, regardless of any If-None-Match sent.
		w.Header().Set("ETag", "e-varies")
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	cache := NewCache(t.TempDir())
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	key := CacheKey(srv.URL, "")

	// 1st: T2 — a normal fetch. Parsed and cached.
	body = downgradeManifest("2026-06-01T00:00:00Z", "e1")
	m1, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("first Fetch (T2): %v", err)
	}
	if m1.GeneratedAt != "2026-06-01T00:00:00Z" {
		t.Fatalf("first fetch generated_at = %q, want T2", m1.GeneratedAt)
	}

	// 2nd: T1 — strictly OLDER than the cached T2. Must be kept-cached, not
	// refused: Fetch returns the CACHED generation with a nil error.
	body = downgradeManifest("2026-05-01T00:00:00Z", "e2")
	var (
		m2       *Manifest
		fetchErr error
	)
	stderr := captureStderr(t, func() {
		m2, fetchErr = Fetch(c, cache)
	})
	if fetchErr != nil {
		t.Fatalf("Fetch must not fail the call on a downgrade, got: %v", fetchErr)
	}
	if m2.GeneratedAt != "2026-06-01T00:00:00Z" {
		t.Errorf("Fetch returned generated_at = %q on a downgrade, want the CACHED generation 2026-06-01T00:00:00Z", m2.GeneratedAt)
	}
	if !strings.Contains(stderr, srv.URL) {
		t.Errorf("stderr warning does not name the server %q: %q", srv.URL, stderr)
	}
	if !strings.Contains(stderr, "2026-05-01T00:00:00Z") || !strings.Contains(stderr, "2026-06-01T00:00:00Z") {
		t.Errorf("stderr warning does not name both timestamps: %q", stderr)
	}

	// The on-disk cache entry's generated_at must be UNCHANGED — keeping the
	// cached manifest must not overwrite it with the downgraded body.
	cachedM, _, ok := cache.Load(key)
	if !ok {
		t.Fatal("cache was wiped by the downgrade")
	}
	if cachedM.GeneratedAt != "2026-06-01T00:00:00Z" {
		t.Errorf("cache overwritten despite keeping the cached manifest: generated_at = %q, want T2", cachedM.GeneratedAt)
	}

	// 3rd: equal generation — proceeds exactly as today (parsed + stored).
	body = downgradeManifest("2026-06-01T00:00:00Z", "e3")
	m3, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("equal-generation Fetch: %v", err)
	}
	if m3.GeneratedAt != "2026-06-01T00:00:00Z" {
		t.Errorf("equal-generation fetch = %+v", m3)
	}

	// 4th: strictly newer generation — proceeds exactly as today.
	body = downgradeManifest("2026-07-01T00:00:00Z", "e4")
	m4, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("newer-generation Fetch: %v", err)
	}
	if m4.GeneratedAt != "2026-07-01T00:00:00Z" {
		t.Errorf("newer-generation fetch = %+v", m4)
	}
	cachedM2, _, ok := cache.Load(key)
	if !ok || cachedM2.GeneratedAt != "2026-07-01T00:00:00Z" {
		t.Errorf("cache not advanced to the newer generation: %+v ok=%v", cachedM2, ok)
	}
}

// Backward compatibility: a cacheEntry written before this guard existed (the
// pre-change on-disk shape — just {"etag":..., "body":...}, no top-level
// generated_at/manifest_version) must be treated as UNKNOWN generation, not
// "older." Fetch must proceed, nothing panics, and the cache is not wiped —
// even when the fresh manifest is, in absolute terms, older than whatever the
// legacy entry's embedded body happens to contain.
func TestFetchLegacyCacheEntryDegradesGracefully(t *testing.T) {
	var served string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", "e2")
		_, _ = w.Write([]byte(served))
	}))
	defer srv.Close()

	dir := t.TempDir()
	cache := NewCache(dir)
	key := CacheKey(srv.URL, "")

	// Seed the pre-change on-disk shape directly (bypassing Store, which would
	// stamp the new top-level fields).
	legacyBody := downgradeManifest("2026-06-01T00:00:00Z", "e1")
	legacy := []byte(`{"etag":"e1","body":` + legacyBody + `}`)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir cache dir: %v", err)
	}
	if err := os.WriteFile(cache.pathFor(key), legacy, 0o644); err != nil {
		t.Fatalf("seed legacy cache entry: %v", err)
	}

	if _, _, ok := cache.CachedGeneration(key); ok {
		t.Fatal("CachedGeneration reported a known generation on a legacy (pre-change) entry")
	}

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	// A fresh manifest older (in absolute terms) than the legacy entry's
	// embedded generated_at. If the guard mistook the legacy entry for a
	// known generation it would refuse this; it must instead proceed.
	served = downgradeManifest("2020-01-01T00:00:00Z", "e2")
	m, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("Fetch against a legacy cache entry must proceed (unknown generation), got: %v", err)
	}
	if m.GeneratedAt != "2020-01-01T00:00:00Z" {
		t.Errorf("fetch result = %+v, want the fresh manifest", m)
	}

	cachedM, _, ok := cache.Load(key)
	if !ok {
		t.Fatal("cache missing after a fetch against a legacy entry — must not be wiped to an unreadable state")
	}
	if cachedM.GeneratedAt != "2020-01-01T00:00:00Z" {
		t.Errorf("cache not updated after fetch: %+v", cachedM)
	}
}
