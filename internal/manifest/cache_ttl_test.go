package manifest

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// cache_ttl_test.go pins the FRESH WINDOW — the part of the manifest cache this
// row is actually about (task-b2f19d3ab4cc9a94).
//
// The ETag cache already existed and already worked. What it bought was a CHEAP
// request; what the census measured was the REQUEST COUNT — GET /v1/capabilities
// at 166,039 hits over 5.04 days on guerrilla, 32% of everything the box served,
// because a 304 is still a round trip and every invocation took one. The window
// is the only thing that turns a cheap request into no request, so these tests
// count requests, never bytes.

// ttlManifest is minimalManifest with a distinguishable etag/generated_at so a
// second version is tellable apart. Kept local so the shared fixture in
// fetch_test.go stays untouched.
func ttlManifest(etag, generatedAt string) string {
	return `{"manifest_version":"1","server":{"name":"x","version":"1","base_url":"http://x"},` +
		`"auth_tier":"none","generated_at":"` + generatedAt + `","etag":"` + etag + `","nouns":[],"commands":[]}`
}

func TestLoadFresh_NoWindowWithoutATTL(t *testing.T) {
	// NewCache is the pre-change constructor and MUST keep revalidating: every
	// existing caller was written against "a Store means the next Fetch sends
	// If-None-Match", and a silent window would change that under them.
	c := NewCache(t.TempDir())
	if err := c.Store("k", []byte(minimalManifest), "e1"); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if _, ok := c.LoadFresh("k"); ok {
		t.Fatal("LoadFresh reported FRESH on a cache built with NewCache (ttl 0) — a zero window must never skip revalidation")
	}
	if _, _, ok := c.Load("k"); !ok {
		t.Fatal("Load lost the entry a ttl-0 Store just wrote")
	}
}

func TestLoadFresh_InsideAndOutsideTheWindow(t *testing.T) {
	dir := t.TempDir()
	c := NewCacheWithTTL(dir, time.Hour)
	if err := c.Store("k", []byte(minimalManifest), "e1"); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if _, ok := c.LoadFresh("k"); !ok {
		t.Fatal("LoadFresh said STALE on an entry stored a moment ago with a one-hour window")
	}

	// Age the entry past the window by rewriting stored_at on disk — the same
	// thing wall-clock time would do, without sleeping for an hour.
	ageEntry(t, dir, -2*time.Hour)
	if _, ok := c.LoadFresh("k"); ok {
		t.Fatal("LoadFresh said FRESH on an entry stored two hours ago with a one-hour window")
	}
}

func TestLoadFresh_RefusesALegacyEntryAndAFutureStamp(t *testing.T) {
	dir := t.TempDir()
	c := NewCacheWithTTL(dir, time.Hour)
	if err := c.Store("k", []byte(minimalManifest), "e1"); err != nil {
		t.Fatalf("Store: %v", err)
	}

	// A future stored_at is a clock that moved backwards (or a copied cache
	// dir). Honouring it would pin the entry "fresh" for however far ahead the
	// stamp sits; revalidating costs one conditional GET.
	ageEntry(t, dir, time.Hour)
	if _, ok := c.LoadFresh("k"); ok {
		t.Fatal("LoadFresh said FRESH on an entry stamped in the FUTURE — an unbounded stale window")
	}

	// A cache file written by a bp that predates the window has no stored_at at
	// all. It must revalidate, not be served blind for a window it never
	// consented to.
	stripStoredAt(t, dir)
	if _, ok := c.LoadFresh("k"); ok {
		t.Fatal("LoadFresh said FRESH on a LEGACY entry that carries no stored_at")
	}
	if _, _, ok := c.Load("k"); !ok {
		t.Fatal("a legacy entry must still be Load-able — it only loses the window, not the body")
	}
}

func TestTouch_SlidesTheWindowAndIsANoopWithoutAnEntry(t *testing.T) {
	dir := t.TempDir()
	c := NewCacheWithTTL(dir, time.Hour)
	if err := c.Store("k", []byte(minimalManifest), "e1"); err != nil {
		t.Fatalf("Store: %v", err)
	}
	ageEntry(t, dir, -2*time.Hour)
	if _, ok := c.LoadFresh("k"); ok {
		t.Fatal("setup: the aged entry should be stale before the Touch")
	}
	if err := c.Touch("k"); err != nil {
		t.Fatalf("Touch: %v", err)
	}
	m, ok := c.LoadFresh("k")
	if !ok {
		t.Fatal("Touch did not restart the fresh window — a 304 would then re-ask on every later invocation forever")
	}
	if m == nil || m.ETag != "e1" {
		t.Fatalf("Touch changed the body it was only supposed to re-stamp: %+v", m)
	}

	// Nothing to touch is not an error, and must not invent an entry: the next
	// 304 would trust a body that does not exist.
	if err := c.Touch("absent"); err != nil {
		t.Fatalf("Touch on a missing key = %v, want nil (no-op)", err)
	}
	if _, _, ok := c.Load("absent"); ok {
		t.Fatal("Touch INVENTED a cache entry for a key that had none")
	}
}

// TestFetch_InsideTheWindowMakesNoRequestAtAll is the row's whole claim at the
// manifest layer: not a cheaper request — no request.
func TestFetch_InsideTheWindowMakesNoRequestAtAll(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	cache := NewCacheWithTTL(t.TempDir(), time.Hour)
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	for i := 0; i < 5; i++ {
		if _, err := Fetch(c, cache); err != nil {
			t.Fatalf("Fetch %d: %v", i, err)
		}
	}
	if hits != 1 {
		t.Fatalf("GET %s = %d over 5 Fetches inside the window, want exactly 1 — the window must skip the request, not just its body", CapabilitiesPath, hits)
	}
}

// A 304 must re-stamp the window, or the request count is bounded by nothing
// once the first window lapses.
func TestFetch_A304RestartsTheWindow(t *testing.T) {
	dir := t.TempDir()
	conditional := 0
	total := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		total++
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

	cache := NewCacheWithTTL(dir, time.Hour)
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})

	if _, err := Fetch(c, cache); err != nil { // 200, stores
		t.Fatalf("first Fetch: %v", err)
	}
	ageEntry(t, dir, -2*time.Hour) // window lapses
	if _, err := Fetch(c, cache); err != nil {
		t.Fatalf("second Fetch: %v", err)
	}
	if conditional != 1 {
		t.Fatalf("an expired window should revalidate exactly once; conditional=%d", conditional)
	}
	// Third: the 304 restarted the window, so this one asks nothing.
	if _, err := Fetch(c, cache); err != nil {
		t.Fatalf("third Fetch: %v", err)
	}
	if total != 2 {
		t.Fatalf("GET %s = %d, want 2 (one 200, one 304) — the third Fetch must ride the window the 304 restarted", CapabilitiesPath, total)
	}
}

// TestFetch_ADifferentServerNeverGetsTheFirstServersManifest is criterion 1's
// keying clause. bp is routinely pointed at guerrilla and at a local instance;
// a shared cache dir must keep them in separate slots.
func TestFetch_ADifferentServerNeverGetsTheFirstServersManifest(t *testing.T) {
	dir := t.TempDir()

	srvA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", "etag-A")
		_, _ = w.Write([]byte(ttlManifest("etag-A", "2026-01-01T00:00:00Z")))
	}))
	defer srvA.Close()
	hitsB := 0
	srvB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hitsB++
		w.Header().Set("ETag", "etag-B")
		_, _ = w.Write([]byte(ttlManifest("etag-B", "2026-01-02T00:00:00Z")))
	}))
	defer srvB.Close()

	// One cache dir, a generous window, two servers.
	cache := NewCacheWithTTL(dir, time.Hour)

	mA, err := Fetch(apiclient.New(apiclient.Config{BaseURL: srvA.URL}), cache)
	if err != nil {
		t.Fatalf("Fetch(A): %v", err)
	}
	if mA.ETag != "etag-A" {
		t.Fatalf("server A manifest etag = %q, want etag-A", mA.ETag)
	}

	mB, err := Fetch(apiclient.New(apiclient.Config{BaseURL: srvB.URL}), cache)
	if err != nil {
		t.Fatalf("Fetch(B): %v", err)
	}
	if mB.ETag != "etag-B" {
		t.Fatalf("server B was served server A's manifest (etag=%q) — the cache key is not server-scoped", mB.ETag)
	}
	if hitsB != 1 {
		t.Fatalf("server B saw %d requests, want 1 — A's fresh entry must not satisfy B", hitsB)
	}
}

// The window is per-CREDENTIAL as well as per-server: a manifest is auth-tier
// baked, so an admin's fresh entry must never be served to an anonymous caller.
func TestFetch_TheWindowIsKeyedOnTheCredentialToo(t *testing.T) {
	hits := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	cache := NewCacheWithTTL(t.TempDir(), time.Hour)
	if _, err := Fetch(apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "tok-a"}), cache); err != nil {
		t.Fatalf("Fetch(tok-a): %v", err)
	}
	if _, err := Fetch(apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "tok-b"}), cache); err != nil {
		t.Fatalf("Fetch(tok-b): %v", err)
	}
	if hits != 2 {
		t.Fatalf("GET %s = %d for two distinct credentials, want 2 — one token's fresh window must not cover another's", CapabilitiesPath, hits)
	}
}

// A nil cache is what --no-cache passes down: an unconditional GET every time,
// and nothing written anywhere.
func TestFetch_ANilCacheAlwaysAsksAndNeverWrites(t *testing.T) {
	dir := t.TempDir()
	hits := 0
	conditional := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		if r.Header.Get("If-None-Match") != "" {
			conditional++
		}
		w.Header().Set("ETag", "e1")
		_, _ = w.Write([]byte(minimalManifest))
	}))
	defer srv.Close()

	// Pre-warm a real cache so "the read was bypassed" is a claim with teeth:
	// a fresh entry sits on disk that a caching Fetch would have served.
	warm := NewCacheWithTTL(dir, time.Hour)
	c := apiclient.New(apiclient.Config{BaseURL: srv.URL})
	if _, err := Fetch(c, warm); err != nil {
		t.Fatalf("warm Fetch: %v", err)
	}
	before := dirSnapshot(t, dir)
	if hits != 1 {
		t.Fatalf("setup: warm fetch hits=%d, want 1", hits)
	}

	for i := 0; i < 3; i++ {
		if _, err := Fetch(c, nil); err != nil {
			t.Fatalf("Fetch(nil cache) %d: %v", i, err)
		}
	}
	if hits != 4 {
		t.Fatalf("GET %s = %d, want 4 (1 warm + 3 uncached) — a nil cache must bypass the READ", CapabilitiesPath, hits)
	}
	if conditional != 0 {
		t.Fatalf("a nil cache sent %d conditional request(s) — it has no ETag to send", conditional)
	}
	if after := dirSnapshot(t, dir); !sameFiles(before, after) {
		t.Fatalf("a nil cache WROTE to the cache dir:\nbefore %v\nafter  %v", before, after)
	}
}

// --- helpers -------------------------------------------------------------

// ageEntry shifts stored_at on the single cache file in dir by d (negative =
// older). It edits the JSON generically rather than reaching for package
// internals, so it also proves the on-disk field is really what the window is
// decided on.
func ageEntry(t *testing.T, dir string, d time.Duration) {
	t.Helper()
	path, obj := soleEntry(t, dir)
	raw, _ := obj["stored_at"].(string)
	if raw == "" {
		t.Fatalf("cache entry %s has no stored_at to age", path)
	}
	ts, err := time.Parse(time.RFC3339Nano, raw)
	if err != nil {
		t.Fatalf("stored_at %q does not parse: %v", raw, err)
	}
	obj["stored_at"] = ts.Add(d).UTC().Format(time.RFC3339Nano)
	writeEntryFile(t, path, obj)
}

// stripStoredAt rewrites the entry into the pre-window shape (no stored_at).
func stripStoredAt(t *testing.T, dir string) {
	t.Helper()
	path, obj := soleEntry(t, dir)
	delete(obj, "stored_at")
	writeEntryFile(t, path, obj)
}

func soleEntry(t *testing.T, dir string) (string, map[string]any) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil || len(paths) != 1 {
		t.Fatalf("want exactly one cache entry in %s, got %v (err %v)", dir, paths, err)
	}
	raw, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatalf("read %s: %v", paths[0], err)
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		t.Fatalf("decode %s: %v", paths[0], err)
	}
	return paths[0], obj
}

func writeEntryFile(t *testing.T, path string, obj map[string]any) {
	t.Helper()
	out, err := json.Marshal(obj)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// sameFiles compares two dirSnapshots by name and content.
func sameFiles(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

// dirSnapshot returns name -> content for every file in dir, so "the cache dir
// was untouched" is checked by CONTENT, not by an mtime that a fast test can
// fail to advance.
func dirSnapshot(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return out
		}
		t.Fatalf("readdir %s: %v", dir, err)
	}
	for _, e := range entries {
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		out[e.Name()] = string(b)
	}
	return out
}
