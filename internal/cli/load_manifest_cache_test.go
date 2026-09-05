package cli

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// load_manifest_cache_test.go is the CLI-level proof for task-b2f19d3ab4cc9a94:
// two consecutive `bp` INVOCATIONS against one server issue ONE
// GET /v1/capabilities.
//
// "Invocation", not "call": the per-process memo in load.go already collapses N
// calls inside ONE process to one fetch, and the census this row carries is
// about separate processes — 166,039 capabilities requests over 5.04 days on
// guerrilla, 32% of everything the box served, one per `bp` the fleet ran.
// resetManifestMemo() between loads is what makes each load a fresh PROCESS;
// the temp XDG_CACHE_HOME persists across them exactly as a real ~/.cache does.
//
// WHAT WAS ALREADY THERE, AND WHAT WAS NOT. The on-disk ETag cache existed
// (internal/manifest/cache.go) and worked: the second invocation sent
// If-None-Match and got a 304. But a 304 IS a request — the same token lookup
// in the same auth plug, the byte savings landing on a body nobody was paying
// for. The missing half was a FRESH WINDOW: a span in which bp does not ask at
// all. These tests count requests.

// twoServerManifest builds a manifest whose etag is distinguishable, so a test
// can tell WHICH server (or WHICH generation) answered.
func cacheTestManifest(etag, generatedAt string) string {
	return `{
  "manifest_version":"1",
  "server":{"name":"t","version":"0","base_url":"http://x"},
  "auth_tier":"admin","generated_at":"` + generatedAt + `","etag":"` + etag + `",
  "nouns":[{"name":"task","summary":"tasks"}],
  "commands":[
    {"id":"task.ls","noun":"task","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/tasks"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}
  ]
}`
}

// capabilitiesLog is capabilitiesCounter with a per-request TRANSCRIPT and a
// swappable ETag, so a test can paste what the server actually saw rather than
// assert a bare number.
type capabilitiesLog struct {
	mu   sync.Mutex
	rows []string
	etag string
	gen  string
}

func newCapabilitiesLog(t *testing.T, etag, gen string) (url string, log *capabilitiesLog) {
	t.Helper()
	log = &capabilitiesLog{etag: etag, gen: gen}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.mu.Lock()
		etag, gen := log.etag, log.gen
		inm := r.Header.Get("If-None-Match")
		status := "200"
		if inm == etag {
			status = "304"
		}
		if r.URL.Path == manifest.CapabilitiesPath {
			log.rows = append(log.rows, "GET "+r.URL.Path+" If-None-Match="+q(inm)+" -> "+status)
		}
		log.mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("ETag", etag)
		if status == "304" {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		_, _ = w.Write([]byte(cacheTestManifest(etag, gen)))
	}))
	t.Cleanup(srv.Close)
	return srv.URL, log
}

func q(s string) string {
	if s == "" {
		return "(none)"
	}
	return `"` + s + `"`
}

func (l *capabilitiesLog) hits() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.rows)
}

func (l *capabilitiesLog) transcript() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := ""
	for i, r := range l.rows {
		out += "\n  " + strconv.Itoa(i+1) + ". " + r
	}
	if out == "" {
		return "\n  (no requests)"
	}
	return out
}

func (l *capabilitiesLog) setETag(etag, gen string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.etag, l.gen = etag, gen
}

// invoke runs one `bp` INVOCATION's manifest acquisition: a fresh process memo,
// the same on-disk cache dir, the same server.
func invoke(t *testing.T, g globals, ctx manifest.Context) *manifest.Manifest {
	t.Helper()
	resetManifestMemo()
	m, err := loadManifest(g, ctx)
	if err != nil {
		t.Fatalf("loadManifest: %v", err)
	}
	return m
}

// TestTwoConsecutiveInvocationsIssueOneCapabilitiesRequest is criterion 0,
// verbatim. RED before the fresh window: the second invocation revalidated and
// the server saw two requests (one 200, one 304).
func TestTwoConsecutiveInvocationsIssueOneCapabilitiesRequest(t *testing.T) {
	isolatedEnv(t)
	t.Cleanup(resetManifestMemo)

	url, log := newCapabilitiesLog(t, "e1", "2026-01-01T00:00:00Z")
	g := globals{server: url}
	ctx := manifest.Context{Server: url, Token: "tok"}

	invoke(t, g, ctx)
	invoke(t, g, ctx)

	if got := log.hits(); got != 1 {
		t.Fatalf("two consecutive bp invocations issued %d GET %s, want exactly 1. server transcript:%s",
			got, manifest.CapabilitiesPath, log.transcript())
	}
	t.Logf("server transcript for two consecutive invocations:%s", log.transcript())
}

// Ten invocations inside one window is still one request — the shape a fleet
// actually produces, and the shape the census measured going wrong.
func TestTenInvocationsInsideTheWindowIssueOneCapabilitiesRequest(t *testing.T) {
	isolatedEnv(t)
	t.Cleanup(resetManifestMemo)

	url, log := newCapabilitiesLog(t, "e1", "2026-01-01T00:00:00Z")
	g := globals{server: url}
	ctx := manifest.Context{Server: url, Token: "tok"}

	for i := 0; i < 10; i++ {
		invoke(t, g, ctx)
	}
	if got := log.hits(); got != 1 {
		t.Fatalf("ten invocations issued %d GET %s, want 1. transcript:%s", got, manifest.CapabilitiesPath, log.transcript())
	}
}

// TestADifferentServerNeverGetsTheFirstServersManifest is criterion 1's keying
// clause at the CLI layer: one cache dir, one process, two servers.
func TestADifferentServerNeverGetsTheFirstServersManifest(t *testing.T) {
	isolatedEnv(t)
	t.Cleanup(resetManifestMemo)

	urlA, _ := newCapabilitiesLog(t, "etag-A", "2026-01-01T00:00:00Z")
	urlB, logB := newCapabilitiesLog(t, "etag-B", "2026-01-02T00:00:00Z")

	mA := invoke(t, globals{server: urlA}, manifest.Context{Server: urlA, Token: "tok"})
	if mA.ETag != "etag-A" {
		t.Fatalf("server A manifest etag = %q, want %q", mA.ETag, "etag-A")
	}
	mB := invoke(t, globals{server: urlB}, manifest.Context{Server: urlB, Token: "tok"})
	if mB.ETag != "etag-B" {
		t.Fatalf("pointing bp at a DIFFERENT server served the first server's manifest (etag=%q, want %q) — the cache key is not server-scoped", mB.ETag, "etag-B")
	}
	if got := logB.hits(); got != 1 {
		t.Fatalf("server B saw %d requests, want 1 — A's fresh entry must not satisfy B", got)
	}
	// And back to A, still inside A's window: no new request to A.
	mA2 := invoke(t, globals{server: urlA}, manifest.Context{Server: urlA, Token: "tok"})
	if mA2.ETag != "etag-A" {
		t.Fatalf("returning to server A served etag %q, want %q", mA2.ETag, "etag-A")
	}
}

// TestNoCacheBypassesBothTheReadAndTheWrite is criterion 2's first clause. The
// read: the hit counter increments on every invocation. The write: the cache
// dir is byte-identical afterwards.
func TestNoCacheBypassesBothTheReadAndTheWrite(t *testing.T) {
	isolatedEnv(t)
	t.Cleanup(resetManifestMemo)

	url, log := newCapabilitiesLog(t, "e1", "2026-01-01T00:00:00Z")
	ctx := manifest.Context{Server: url, Token: "tok"}

	// Warm the cache with a normal invocation, so "the read was bypassed" has
	// teeth: a fresh entry is sitting on disk that a cached run would serve.
	invoke(t, globals{server: url}, ctx)
	if got := log.hits(); got != 1 {
		t.Fatalf("setup: warm invocation issued %d requests, want 1", got)
	}
	cacheDir := manifest.DefaultCacheDir()
	before := cacheSnapshot(t, cacheDir)
	if len(before) == 0 {
		t.Fatalf("setup: the warm invocation wrote nothing to %s — the rest of this test would be vacuous", cacheDir)
	}

	for i := 0; i < 3; i++ {
		invoke(t, globals{server: url, noCache: true}, ctx)
	}
	if got := log.hits(); got != 4 {
		t.Fatalf("GET %s = %d, want 4 (1 warm + 3 --no-cache) — --no-cache must bypass the READ. transcript:%s",
			manifest.CapabilitiesPath, got, log.transcript())
	}
	if after := cacheSnapshot(t, cacheDir); !sameSnapshot(before, after) {
		t.Fatalf("--no-cache WROTE to %s — it must bypass the write too, so it diagnoses the cache instead of silently repairing it", cacheDir)
	}
	t.Logf("--no-cache transcript (note every request is unconditional — no If-None-Match):%s", log.transcript())
}

// TestStaleManifestIsBoundedByTheWindowAndEscapableImmediately is criterion 2's
// second clause, resolved HONESTLY.
//
// The criterion asks that a changed server ETag be picked up by "the very next
// invocation rather than serving the old one until the TTL expires". With a
// pure TTL that is not achievable without a request, and there is no piggyback
// signal to ride: no ordinary Barkpark API response carries a manifest
// generation header (checked across api/lib/barkpark_web — the only etag
// headers are per-resource ones on papers, SCIM and the cycle-fleet gate), and
// this row's fence forbids adding one. So the resolution is:
//
//   - the window is SHORT (manifest.DefaultManifestTTL, 60s) and that stale
//     span is the documented, bounded cost;
//   - the FIRST invocation after the window picks the new manifest up, via the
//     conditional GET the cache has always done;
//   - `--no-cache` picks it up IMMEDIATELY, on the very next invocation.
//
// This test pins all three.
func TestStaleManifestIsBoundedByTheWindowAndEscapableImmediately(t *testing.T) {
	isolatedEnv(t)
	t.Cleanup(resetManifestMemo)

	url, log := newCapabilitiesLog(t, "e1", "2026-01-01T00:00:00Z")
	g := globals{server: url}
	ctx := manifest.Context{Server: url, Token: "tok"}

	if m := invoke(t, g, ctx); m.ETag != "e1" {
		t.Fatalf("first invocation etag = %q, want %q", m.ETag, "e1")
	}

	// The server redeploys: new manifest, new ETag.
	log.setETag("e2", "2026-01-02T00:00:00Z")

	// Inside the window, bp keeps the old tree — the bounded cost, asserted so
	// it is a DOCUMENTED bound and not an accident.
	if m := invoke(t, g, ctx); m.ETag != "e1" {
		t.Fatalf("inside the %s window the cached manifest should still be served; got etag %q", manifest.DefaultManifestTTL, m.ETag)
	}
	if got := log.hits(); got != 1 {
		t.Fatalf("an in-window invocation asked the server anyway (%d hits)", got)
	}

	// --no-cache picks the new manifest up on the VERY NEXT invocation.
	if m := invoke(t, globals{server: url, noCache: true}, ctx); m.ETag != "e2" {
		t.Fatalf("--no-cache served etag %q, want the server's current %q — the escape hatch does not escape", m.ETag, "e2")
	}

	// And once the window lapses, an ordinary invocation picks it up too. Aged
	// on disk rather than slept for: the window is 60s and a test must not be.
	ageCacheEntries(t, manifest.DefaultCacheDir(), -2*manifest.DefaultManifestTTL)
	if m := invoke(t, g, ctx); m.ETag != "e2" {
		t.Fatalf("after the window lapsed the invocation served etag %q, want the server's current %q", m.ETag, "e2")
	}
	t.Logf("stale-window transcript:%s", log.transcript())
}

// --- helpers -------------------------------------------------------------

func cacheSnapshot(t *testing.T, dir string) map[string]string {
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

func sameSnapshot(a, b map[string]string) bool {
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

// ageCacheEntries shifts stored_at on every cache file in dir by d, standing in
// for wall-clock time. It edits the JSON generically — which also proves the
// window is decided on the on-disk field and nothing else.
func ageCacheEntries(t *testing.T, dir string, d time.Duration) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		t.Fatalf("glob %s: %v", dir, err)
	}
	if len(paths) == 0 {
		t.Fatalf("no cache entries under %s to age", dir)
	}
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s: %v", p, err)
		}
		var obj map[string]any
		if err := json.Unmarshal(raw, &obj); err != nil {
			t.Fatalf("decode %s: %v", p, err)
		}
		s, _ := obj["stored_at"].(string)
		if s == "" {
			t.Fatalf("cache entry %s carries no stored_at — the window has nothing to age", p)
		}
		ts, err := time.Parse(time.RFC3339Nano, s)
		if err != nil {
			t.Fatalf("stored_at %q in %s does not parse: %v", s, p, err)
		}
		obj["stored_at"] = ts.Add(d).UTC().Format(time.RFC3339Nano)
		out, err := json.Marshal(obj)
		if err != nil {
			t.Fatalf("marshal %s: %v", p, err)
		}
		if err := os.WriteFile(p, out, 0o644); err != nil {
			t.Fatalf("write %s: %v", p, err)
		}
	}
}
