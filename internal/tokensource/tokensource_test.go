package tokensource

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// rotatingCP accepts exactly one bearer at a time; accept() swaps it (the
// supersede-mint revoking the old token). It records every hit and the body
// each accepted request carried.
type rotatingCP struct {
	mu       sync.Mutex
	accepted string
	hits     atomic.Int64
	bodies   []string
}

func (c *rotatingCP) accept(tok string) { c.mu.Lock(); c.accepted = tok; c.mu.Unlock() }

func (c *rotatingCP) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.hits.Add(1)
	body, _ := io.ReadAll(r.Body)
	c.mu.Lock()
	ok := r.Header.Get("Authorization") == "Bearer "+c.accepted
	if ok {
		c.bodies = append(c.bodies, string(body))
	}
	c.mu.Unlock()
	if !ok {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func writeToken(t *testing.T, path, tok string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(tok+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

// post sends one authenticated POST the way the daemons do: the caller
// attaches Authorization from Token(), the wrapped client does the rest.
func post(t *testing.T, c *http.Client, src *Source, url, body string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+src.Token())
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	return resp.StatusCode
}

// The token file is rewritten A→B mid-run while the server moves from
// accepting A to accepting only B. The same client recovers with no restart,
// on the very request that met the 401, and replays the body intact.
func TestRewrittenTokenFile_RecoversWithoutRestart(t *testing.T) {
	cp := &rotatingCP{}
	cp.accept("token-A")
	srv := httptest.NewServer(cp)
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "agent.token")
	writeToken(t, path, "token-A")
	src, err := FromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	c := src.Client(srv.Client())

	if got := post(t, c, src, srv.URL, "one"); got != 200 {
		t.Fatalf("with token A accepted: status %d, want 200", got)
	}

	// Supersede-mint: server revokes A, provisioning rewrites the file to B.
	cp.accept("token-B")
	writeToken(t, path, "token-B")

	before := cp.hits.Load()
	if got := post(t, c, src, srv.URL, "two"); got != 200 {
		t.Fatalf("after rewrite to B: status %d, want 200 (client must re-read the file on 401)", got)
	}
	if n := cp.hits.Load() - before; n != 2 {
		t.Fatalf("recovery took %d server hits, want exactly 2 (401 + one replay)", n)
	}
	if src.Token() != "token-B" {
		t.Fatalf("cached token = %q, want token-B", src.Token())
	}

	// Steady state on B: one hit per request, no disk-driven retries.
	before = cp.hits.Load()
	if got := post(t, c, src, srv.URL, "three"); got != 200 {
		t.Fatalf("steady state on B: status %d", got)
	}
	if n := cp.hits.Load() - before; n != 1 {
		t.Fatalf("steady-state request took %d hits, want 1", n)
	}
	if strings.Join(cp.bodies, ",") != "one,two,three" {
		t.Fatalf("accepted bodies = %v, want [one two three] (replay must resend the body)", cp.bodies)
	}
}

// A 401 while the file still holds the refused token is returned as-is:
// exactly one server hit per request, never a loop.
func TestUnchangedFile_401IsNotRetried(t *testing.T) {
	cp := &rotatingCP{}
	cp.accept("token-B") // server already rotated; file never rewritten
	srv := httptest.NewServer(cp)
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "agent.token")
	writeToken(t, path, "token-A")
	src, err := FromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	c := src.Client(srv.Client())

	const n = 5
	for i := 0; i < n; i++ {
		if got := post(t, c, src, srv.URL, "x"); got != http.StatusUnauthorized {
			t.Fatalf("request %d: status %d, want 401 passed through", i, got)
		}
	}
	if got := cp.hits.Load(); got != n {
		t.Fatalf("%d requests produced %d server hits, want %d (no retry on an unchanged file)", n, got, n)
	}
}

// A literal --token has no file: its 401s pass through with no retry, as
// before this package existed.
func TestLiteral_401IsNotRetried(t *testing.T) {
	cp := &rotatingCP{}
	cp.accept("other")
	srv := httptest.NewServer(cp)
	defer srv.Close()

	src := Literal("lit")
	c := src.Client(srv.Client())
	if got := post(t, c, src, srv.URL, "x"); got != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", got)
	}
	if got := cp.hits.Load(); got != 1 {
		t.Fatalf("hits = %d, want 1", got)
	}
}

// Two requests carrying the stale token 401 together. The first reload swaps
// the cache; the second must still replay, because what it SENT is stale.
func TestConcurrentStaleRequestsBothReplay(t *testing.T) {
	cp := &rotatingCP{}
	cp.accept("token-B")
	srv := httptest.NewServer(cp)
	defer srv.Close()

	path := filepath.Join(t.TempDir(), "agent.token")
	writeToken(t, path, "token-A")
	src, err := FromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	c := src.Client(srv.Client())
	stale := src.Token()
	writeToken(t, path, "token-B")

	for i := 0; i < 2; i++ {
		req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
		req.Header.Set("Authorization", "Bearer "+stale)
		resp, err := c.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("stale request %d: status %d, want 200", i, resp.StatusCode)
		}
	}
}

// A request with no Authorization header is never given one — so a redirect
// to another host, which http.Client strips of Authorization, stays bare.
func TestCrossHostRedirect_TokenNotReattached(t *testing.T) {
	var sawAuth atomic.Value
	sawAuth.Store("")
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sawAuth.Store(r.Header.Get("Authorization"))
		w.WriteHeader(200)
	}))
	defer other.Close()
	// 127.0.0.1 vs localhost: a different host to http.Client's redirect rule.
	otherURL := strings.Replace(other.URL, "127.0.0.1", "localhost", 1)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, otherURL, http.StatusFound)
	}))
	defer origin.Close()

	src := Literal("secret")
	c := src.Client(&http.Client{})
	req, _ := http.NewRequest(http.MethodGet, origin.URL, nil)
	req.Header.Set("Authorization", "Bearer "+src.Token())
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if got := sawAuth.Load().(string); got != "" {
		t.Fatalf("cross-host redirect target received Authorization %q; want none", got)
	}
}

// A half-written (empty) rewrite must not blank the cached credential.
func TestReload_EmptyFileKeepsCachedToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.token")
	writeToken(t, path, "token-A")
	src, err := FromFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if got := src.Reload(); got != "token-A" {
		t.Fatalf("Reload over an empty file = %q, want token-A kept", got)
	}
}

func TestResolve(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent.token")
	writeToken(t, path, "  from-file \n")

	if s, err := Resolve("lit", path); err != nil || s.Token() != "lit" {
		t.Fatalf("literal must win: %v %v", s, err)
	}
	if s, err := Resolve("", path); err != nil || s.Token() != "from-file" {
		t.Fatalf("file: %v %v", s, err)
	}
	if _, err := Resolve("", ""); err != ErrNoToken {
		t.Fatalf("neither: err = %v, want ErrNoToken", err)
	}
	if _, err := Resolve("", filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatalf("missing file must fail at start")
	}
	empty := filepath.Join(t.TempDir(), "empty")
	writeToken(t, empty, "   ")
	if _, err := Resolve("", empty); err == nil {
		t.Fatalf("whitespace-only file must fail at start")
	}
}
