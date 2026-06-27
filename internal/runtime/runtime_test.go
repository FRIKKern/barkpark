package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/caddyfile"
)

// --- scripted control plane --------------------------------------------------

type scriptedCP struct {
	t              *testing.T
	mu             sync.Mutex
	pending        []claimReply // exhausted in order
	idx            int
	transitions    []map[string]any
	transitionCode int
}

type claimReply struct {
	deployment Deployment
	epoch      int
}

func newCP(t *testing.T) *scriptedCP { return &scriptedCP{t: t} }

func (s *scriptedCP) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/agent/deployments/claim", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		s.mu.Lock()
		var reply *claimReply
		if s.idx < len(s.pending) {
			reply = &s.pending[s.idx]
			s.idx++
		}
		s.mu.Unlock()
		if reply == nil {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"no_pending"}`))
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"deployment":     reply.deployment,
			"observed_epoch": reply.epoch,
		})
	})

	mux.HandleFunc("/v1/agent/deployments/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if !strings.HasSuffix(r.URL.Path, "/transition") {
			http.NotFound(w, r)
			return
		}
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		s.mu.Lock()
		s.transitions = append(s.transitions, body)
		code := s.transitionCode
		s.mu.Unlock()
		if code == 0 {
			code = http.StatusOK
		}
		w.WriteHeader(code)
		_, _ = w.Write([]byte(`{"deployment":{"status":"`))
		if v, ok := body["status"].(string); ok {
			_, _ = w.Write([]byte(v))
		}
		_, _ = w.Write([]byte(`"}}`))
	})

	return mux
}

// --- scripted runner / FS / port allocator -----------------------------------

type fakeRunner struct {
	calls         []call
	failOn        map[string]error // first arg → err
	healthURL     string           // optional: if set, register a synthetic health responder
	healthRespond http.Handler
}

type call struct {
	name string
	args []string
}

func (r *fakeRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	r.calls = append(r.calls, call{name: name, args: append([]string(nil), args...)})
	if err, ok := r.failOn[name]; ok {
		return err
	}
	return nil
}

type mapFS struct{ files map[string][]byte }

func newMapFS() *mapFS { return &mapFS{files: map[string][]byte{}} }

func (m *mapFS) WriteFile(path string, data []byte, perm uint32) error {
	m.files[path] = append([]byte(nil), data...)
	return nil
}

func (m *mapFS) ReadFile(path string) ([]byte, error) {
	if b, ok := m.files[path]; ok {
		return b, nil
	}
	return nil, errors.New("not found")
}

type fixedPorts struct{ next int }

func (f *fixedPorts) Allocate(inUse map[int]bool) (int, error) {
	p := f.next
	for inUse[p] {
		p++
	}
	return p, nil
}

// --- tests -------------------------------------------------------------------

func TestRunOnce_QueueEmpty(t *testing.T) {
	cp := newCP(t)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	e := &Executor{
		ControlURL: srv.URL,
		AgentToken: "test-token",
		WorkerID:   "agent-1",
		HTTPClient: srv.Client(),
		Runner:     &fakeRunner{},
		FS:         newMapFS(),
		Ports:      &fixedPorts{next: 7001},
	}
	had, err := e.RunOnce(context.Background(), State{})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if had {
		t.Fatalf("expected false, got true")
	}
}

func TestRunOnce_HappyPath_FirstDeploy_BluelessSiteGoesLive(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-12345678abcdef",
			SiteID:   "s-aabbccdd",
			Status:   "pushing",
			ImageTag: "site-shop-d-12345678",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 1,
	}}

	// Stand up a tiny synthetic container responder on a known port so the
	// real healthCheck() sees a 200 fast — avoids the 30s default timeout.
	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()
	containerPort := mustPort(t, containerSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	fs := newMapFS()
	runner := &fakeRunner{}

	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		AskGateURL:    "https://cloud.barkpark.cloud/v1/tls/ask",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            fs,
		Ports:         &fixedPorts{next: containerPort}, // returns the synthetic responder's port
		HealthTimeout: 2 * time.Second,
	}

	// First deploy on this box for this site — state has no live entry yet;
	// the executor reads slug + domains from the inlined Site on the claim.
	state := State{}

	had, err := e.RunOnce(context.Background(), state)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}

	// 1. docker load was the first runner call.
	if len(runner.calls) == 0 || runner.calls[0].name != "sh" {
		t.Fatalf("expected docker load via sh, got %+v", runner.calls)
	}
	if !strings.Contains(strings.Join(runner.calls[0].args, " "), "docker load -i") {
		t.Errorf("first call args missing docker load: %v", runner.calls[0].args)
	}
	if !strings.Contains(strings.Join(runner.calls[0].args, " "), "site-shop-d-12345678.tar") {
		t.Errorf("docker load did not reference image tag in args: %v", runner.calls[0].args)
	}

	// 2. docker run with port + memory + cpu caps.
	if len(runner.calls) < 2 || runner.calls[1].name != "docker" {
		t.Fatalf("expected docker run, got %+v", runner.calls)
	}
	dockerArgs := strings.Join(runner.calls[1].args, " ")
	if !strings.Contains(dockerArgs, "--memory=512m") {
		t.Errorf("docker run missing memory cap: %v", dockerArgs)
	}
	if !strings.Contains(dockerArgs, "--cpus=1") {
		t.Errorf("docker run missing cpu cap: %v", dockerArgs)
	}

	// 3. Caddyfile rewritten with the new site's port.
	caddy, ok := fs.files["/etc/caddy/Caddyfile"]
	if !ok {
		t.Fatalf("Caddyfile was not written")
	}
	if !strings.Contains(string(caddy), "on_demand_tls") {
		t.Errorf("Caddyfile missing on_demand_tls block: %s", caddy)
	}
	if !strings.Contains(string(caddy), "shop.example.com") {
		t.Errorf("Caddyfile missing site domain: %s", caddy)
	}

	// 4. caddy reload called.
	reloadCalled := false
	for _, c := range runner.calls {
		if c.name == "caddy" {
			reloadCalled = true
			break
		}
	}
	if !reloadCalled {
		t.Errorf("caddy reload not called: %+v", runner.calls)
	}

	// 5. transition POST: status=live, make_current=true, site_port set.
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	tr := cp.transitions[0]
	if tr["status"] != "live" {
		t.Errorf("transition status = %v, want live", tr["status"])
	}
	if tr["make_current"] != true {
		t.Errorf("transition make_current = %v, want true", tr["make_current"])
	}
	if _, ok := tr["site_port"]; !ok {
		t.Errorf("transition missing site_port: %+v", tr)
	}
	if epoch, _ := tr["observed_epoch"].(float64); int(epoch) != 1 {
		t.Errorf("transition observed_epoch = %v, want 1", tr["observed_epoch"])
	}
}

func TestRunOnce_DockerLoadFails_TransitionsFailed(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-failure",
			SiteID:   "s-failure",
			Status:   "pushing",
			ImageTag: "site-broken-tag",
		},
		epoch: 1,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{failOn: map[string]error{"sh": errors.New("exit status 1: no such file")}}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            newMapFS(),
		Ports:         &fixedPorts{next: 7001},
		HealthTimeout: time.Second,
	}

	had, err := e.RunOnce(context.Background(), State{})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true even on failure")
	}
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	tr := cp.transitions[0]
	if tr["status"] != "failed" {
		t.Errorf("transition status = %v, want failed", tr["status"])
	}
	reason, _ := tr["failure_reason"].(string)
	if !strings.Contains(reason, "docker load") {
		t.Errorf("failure_reason should mention docker load: %q", reason)
	}
	// On a load failure the Caddyfile must NOT have been written — no
	// reverse_proxy churn from a half-broken deploy.
}

func TestRunOnce_BlueGreenSwap_NewPortReplacesOld(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-green1234",
			SiteID:   "s-existing",
			Status:   "pushing",
			ImageTag: "site-shop-green",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 4,
	}}

	healthSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer healthSrv.Close()
	greenPort := mustPort(t, healthSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	fs := newMapFS()
	runner := &fakeRunner{}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		AskGateURL:    "https://cloud.barkpark.cloud/v1/tls/ask",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            fs,
		Ports:         &fixedPorts{next: greenPort}, // green port
		HealthTimeout: 2 * time.Second,
	}

	// state has the existing blue site on a different port. Slug must match
	// what resolveSite returns (the inlined Site.Slug = "shop").
	bluePort := greenPort + 100
	state := State{
		LiveSites: []caddyfile.Site{
			{Slug: "shop", Domains: []string{"shop.example.com"}, Port: bluePort},
		},
	}

	had, err := e.RunOnce(context.Background(), state)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}

	// Caddyfile now points at the GREEN port, not blue.
	caddy, _ := fs.files["/etc/caddy/Caddyfile"]
	if !strings.Contains(string(caddy), "127.0.0.1:"+itoa(greenPort)) {
		t.Errorf("Caddyfile should point at green port %d:\n%s", greenPort, caddy)
	}
	if strings.Contains(string(caddy), "127.0.0.1:"+itoa(bluePort)) {
		t.Errorf("Caddyfile should NOT contain old blue port %d:\n%s", bluePort, caddy)
	}

	// transition still atomic on the green's epoch.
	if cp.transitions[0]["observed_epoch"].(float64) != 4 {
		t.Errorf("transition wrong epoch: %v", cp.transitions[0])
	}
}

func TestMergeSite_ReplacesBySlug(t *testing.T) {
	existing := []caddyfile.Site{
		{Slug: "a", Domains: []string{"a.com"}, Port: 7001},
		{Slug: "b", Domains: []string{"b.com"}, Port: 7002},
	}
	out := mergeSite(existing, caddyfile.Site{Slug: "a", Domains: []string{"a.com"}, Port: 7099})
	if len(out) != 2 {
		t.Fatalf("len = %d, want 2", len(out))
	}
	for _, s := range out {
		if s.Slug == "a" && s.Port != 7099 {
			t.Errorf("a's port = %d, want 7099", s.Port)
		}
	}
}

func TestMergeSite_AppendsIfNew(t *testing.T) {
	existing := []caddyfile.Site{{Slug: "a", Domains: []string{"a.com"}, Port: 7001}}
	out := mergeSite(existing, caddyfile.Site{Slug: "b", Domains: []string{"b.com"}, Port: 7002})
	if len(out) != 2 {
		t.Fatalf("len = %d, want 2", len(out))
	}
	if out[1].Slug != "b" {
		t.Errorf("new site should be appended; got slugs %v", []string{out[0].Slug, out[1].Slug})
	}
}

func TestDefaultPortAllocator_PicksLowestFree(t *testing.T) {
	a := DefaultPortAllocator{}
	p, err := a.Allocate(map[int]bool{7001: true, 7002: true, 7004: true})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if p != 7003 {
		t.Errorf("got %d, want 7003", p)
	}
}

// --- small helpers -----------------------------------------------------------

func mustPort(t *testing.T, urlStr string) int {
	t.Helper()
	// httptest URL is http://127.0.0.1:NNNN — take the port.
	i := strings.LastIndex(urlStr, ":")
	if i < 0 {
		t.Fatalf("no port in %q", urlStr)
	}
	var p int
	for _, c := range urlStr[i+1:] {
		if c < '0' || c > '9' {
			break
		}
		p = p*10 + int(c-'0')
	}
	if p == 0 {
		t.Fatalf("no port parsed from %q", urlStr)
	}
	return p
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
