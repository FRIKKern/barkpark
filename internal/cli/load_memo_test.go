package cli

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// load_memo_test.go pins the per-process floor on GET /v1/capabilities
// (task-e2f5ecca0be9a6d1: 338 capabilities requests in five minutes, then 556 in
// ten, against a box whose auth plugs were already the top raising frame). The
// claim is a COUNT, so the test counts.

const memoManifestBody = `{
  "manifest_version":"1",
  "server":{"name":"t","version":"0","base_url":"http://x"},
  "auth_tier":"admin","generated_at":"g","etag":"e",
  "nouns":[{"name":"task","summary":"tasks"}],
  "commands":[
    {"id":"task.ls","noun":"task","verb":"ls","summary":"list","http":{"method":"GET","path_template":"/v1/tasks"},"auth_tier":"read","args":[],"flags":[],"writes":false,"batch":false,"paginated":true,"dry_run":false,"default_output":"table"}
  ]
}`

// capabilitiesCounter serves a valid manifest and tallies every hit on
// /v1/capabilities — including a conditional one, because a 304 is still a
// request, and a request is what costs the struggling server a token lookup.
func capabilitiesCounter(t *testing.T) (url string, hits func() int) {
	t.Helper()
	var mu sync.Mutex
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == manifest.CapabilitiesPath {
			mu.Lock()
			n++
			mu.Unlock()
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("ETag", `"e"`)
		_, _ = w.Write([]byte(memoManifestBody))
	}))
	t.Cleanup(srv.Close)
	return srv.URL, func() int {
		mu.Lock()
		defer mu.Unlock()
		return n
	}
}

func TestLoadManifest_FetchesCapabilitiesOncePerProcess(t *testing.T) {
	isolatedEnv(t)
	resetManifestMemo()
	t.Cleanup(resetManifestMemo)

	url, hits := capabilitiesCounter(t)
	g := globals{server: url}
	ctx := manifest.Context{Server: url, Token: "tok"}

	const calls = 12
	var first *manifest.Manifest
	for i := 0; i < calls; i++ {
		m, err := loadManifest(g, ctx)
		if err != nil {
			t.Fatalf("loadManifest call %d: %v", i, err)
		}
		if m == nil {
			t.Fatalf("loadManifest call %d returned a nil manifest", i)
		}
		if i == 0 {
			first = m
			continue
		}
		if m != first {
			t.Fatalf("call %d returned a DIFFERENT manifest pointer — the memo did not serve it", i)
		}
	}

	if got := hits(); got != 1 {
		t.Fatalf("GET %s = %d over %d loadManifest calls, want exactly 1 per process", manifest.CapabilitiesPath, got, calls)
	}
}

func TestLoadManifest_MemoIsKeyedOnTheCredential(t *testing.T) {
	// A manifest is auth-tier-baked: serving one token's copy to another would
	// hide (or expose) commands. Two tokens must be two fetches.
	isolatedEnv(t)
	resetManifestMemo()
	t.Cleanup(resetManifestMemo)

	url, hits := capabilitiesCounter(t)
	g := globals{server: url}

	if _, err := loadManifest(g, manifest.Context{Server: url, Token: "tok-a"}); err != nil {
		t.Fatalf("loadManifest(tok-a): %v", err)
	}
	if _, err := loadManifest(g, manifest.Context{Server: url, Token: "tok-b"}); err != nil {
		t.Fatalf("loadManifest(tok-b): %v", err)
	}
	if _, err := loadManifest(g, manifest.Context{Server: url, Token: "tok-a"}); err != nil {
		t.Fatalf("loadManifest(tok-a, again): %v", err)
	}

	if got := hits(); got != 2 {
		t.Fatalf("GET %s = %d for two distinct credentials (a, b, a), want 2 — one per identity, and the repeat served from the memo", manifest.CapabilitiesPath, got)
	}
}

func TestLoadManifest_DoesNotMemoiseAFailure(t *testing.T) {
	// A transient refusal must not poison every later call in the same process:
	// that would turn one 429 into a dead binary for its whole run.
	isolatedEnv(t)
	resetManifestMemo()
	t.Cleanup(resetManifestMemo)

	var mu sync.Mutex
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		n++
		attempt := n
		mu.Unlock()
		if attempt == 1 {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"ok":false}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(memoManifestBody))
	}))
	defer srv.Close()

	g := globals{server: srv.URL}
	ctx := manifest.Context{Server: srv.URL, Token: "tok"}

	if _, err := loadManifest(g, ctx); err == nil {
		t.Fatal("the first (500) call did not fail")
	}
	if _, err := loadManifest(g, ctx); err != nil {
		t.Fatalf("the retry after a transient failure was refused from the memo: %v", err)
	}
}
