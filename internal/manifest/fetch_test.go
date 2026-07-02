package manifest

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

const minimalManifest = `{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},"auth_tier":"none","generated_at":"2026-01-01T00:00:00Z","etag":"e1","nouns":[],"commands":[]}`

// Fetch is the ETag-validated manifest read behind every CLI invocation: a 200
// parses + caches; a subsequent request sends If-None-Match and a 304 returns
// the cached manifest without re-parsing. This locks that caching contract.
func TestFetchCachesThenHonors304(t *testing.T) {
	var conditional int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") == "e1" {
			conditional++
			w.Header().Set("ETag", "e1")
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	cache := NewCache(t.TempDir())
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	// 1st: 200 → parse + store.
	m1, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("first Fetch: %v", err)
	}
	if m1 == nil || m1.ManifestVersion != "1" {
		t.Fatalf("first fetch manifest = %+v, want version 1", m1)
	}

	// 2nd: cached ETag → If-None-Match → 304 → returns the cached manifest.
	m2, err := Fetch(c, cache)
	if err != nil {
		t.Fatalf("second Fetch: %v", err)
	}
	if m2 == nil || m2.ManifestVersion != "1" {
		t.Errorf("304 path did not return the cached manifest: %+v", m2)
	}
	if conditional != 1 {
		t.Errorf("second fetch should have sent If-None-Match and gotten one 304; conditional=%d", conditional)
	}
}

// A nil cache disables caching — Fetch does an unconditional GET (no
// If-None-Match) and parses fresh every time.
func TestFetchNilCacheUnconditional(t *testing.T) {
	var sawConditional bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") != "" {
			sawConditional = true
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	m, err := Fetch(c, nil)
	if err != nil {
		t.Fatalf("Fetch(nil cache): %v", err)
	}
	if m == nil || m.ManifestVersion != "1" {
		t.Errorf("nil-cache fetch manifest = %+v", m)
	}
	if sawConditional {
		t.Error("nil cache must not send If-None-Match")
	}
}

// A non-2xx/304 status surfaces as an error, not a nil manifest.
func TestFetchErrorsOnBadStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	if _, err := Fetch(c, nil); err == nil {
		t.Error("Fetch on a 500 returned nil error")
	}
}
