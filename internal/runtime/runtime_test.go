package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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

	// site-env-injection: the env GET /v1/agent/sites/:id/env answers with.
	// nil siteEnv + siteEnvCode 0 → 404, emulating a control plane that
	// predates the route (the deploy must proceed env-less).
	siteEnv     map[string]string
	siteEnvCode int // 0 → 404 when siteEnv is nil, else 200
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

	mux.HandleFunc("/v1/agent/sites/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		if !strings.HasSuffix(r.URL.Path, "/env") {
			http.NotFound(w, r)
			return
		}

		s.mu.Lock()
		env := s.siteEnv
		code := s.siteEnvCode
		s.mu.Unlock()

		switch {
		case code != 0 && code != http.StatusOK:
			w.WriteHeader(code)
			_, _ = w.Write([]byte(`{"error":"decrypt_failed"}`))
		case env == nil:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
		default:
			_ = json.NewEncoder(w).Encode(map[string]any{"env": env})
		}
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
	return nil, fs.ErrNotExist
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

	// 1. docker load was the first runner call — a fixed argv straight to docker
	// (NO `sh -c`), so the image tag can never be shell-expanded.
	if len(runner.calls) == 0 || runner.calls[0].name != "docker" {
		t.Fatalf("expected docker load direct, got %+v", runner.calls)
	}
	loadArgs := strings.Join(runner.calls[0].args, " ")
	if !strings.Contains(loadArgs, "load") || !strings.Contains(loadArgs, "-i") {
		t.Errorf("first call missing load/-i: %v", runner.calls[0].args)
	}
	if !strings.Contains(loadArgs, "site-shop-d-12345678.tar") {
		t.Errorf("docker load did not reference image tag in args: %v", runner.calls[0].args)
	}

	// 2. docker run with port + memory + cpu caps (preceded by the best-effort
	// stale-name `docker rm -f` — see TestRunOnce_RemovesStaleSameNameContainer).
	runArgs := dockerRunCall(runner.calls)
	if runArgs == nil {
		t.Fatalf("expected docker run, got %+v", runner.calls)
	}
	dockerArgs := strings.Join(runArgs, " ")
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

// gh-6: a PREVIEW deployment renders its OWN Caddy block (preview slug + preview
// host, not the production domain), preserves the existing production block, and
// activates WITHOUT make_current — so the production slot is never repointed.
func TestRunOnce_Preview_RendersOwnHost_LeavesProductionSlot(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:          "d-preview01abcdef",
			SiteID:      "s-aabbccdd",
			Status:      "pushing",
			ImageTag:    "site-shop--dev-abc123-d-preview0",
			Environment: "preview",
			Branch:      "dev",
			Site: InlineSite{
				Slug:        "shop",
				Domains:     []string{"shop.example.com"},
				PreviewSlug: "shop--dev-abc123",
				PreviewHost: "shop--dev-abc123.barkpark.cloud",
			},
		},
		epoch: 1,
	}}

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
		Ports:         &fixedPorts{next: containerPort},
		HealthTimeout: 2 * time.Second,
	}

	// The production site is already live — the preview must NOT clobber it.
	state := State{LiveSites: []caddyfile.Site{
		{Slug: "shop", Domains: []string{"shop.example.com"}, Port: 7001},
	}}

	had, err := e.RunOnce(context.Background(), state)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}

	caddy, ok := fs.files["/etc/caddy/Caddyfile"]
	if !ok {
		t.Fatalf("Caddyfile was not written")
	}
	// The preview host is served...
	if !strings.Contains(string(caddy), "shop--dev-abc123.barkpark.cloud") {
		t.Errorf("Caddyfile missing preview host: %s", caddy)
	}
	// ...alongside the preserved production block.
	if !strings.Contains(string(caddy), "shop.example.com") {
		t.Errorf("Caddyfile dropped the production block: %s", caddy)
	}

	// The activation transition must be live WITHOUT make_current / site_port —
	// the production slot is untouched.
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	tr := cp.transitions[0]
	if tr["status"] != "live" {
		t.Errorf("transition status = %v, want live", tr["status"])
	}
	if _, ok := tr["make_current"]; ok {
		t.Errorf("preview transition must NOT set make_current: %+v", tr)
	}
	if _, ok := tr["site_port"]; ok {
		t.Errorf("preview transition must NOT set site_port: %+v", tr)
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

	// docker load is now a direct `docker` exec (no `sh -c`); it is the first
	// docker invocation, so failing "docker" fails the load before anything else.
	runner := &fakeRunner{failOn: map[string]error{"docker": errors.New("exit status 1: no such file")}}
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

func TestRunOnce_CaddyReloadFails_ReapsGreenContainer(t *testing.T) {
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

	// Synthetic container responder so healthCheck() passes fast — the green
	// container comes up healthy, and only the later caddy reload fails.
	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()
	containerPort := mustPort(t, containerSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{failOn: map[string]error{"caddy": errors.New("exit status 1: caddy not running")}}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            newMapFS(),
		Ports:         &fixedPorts{next: containerPort},
		HealthTimeout: 2 * time.Second,
	}

	had, err := e.RunOnce(context.Background(), State{})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true even on caddy reload failure")
	}

	// The deploy transitions to failed with a caddy-reload reason.
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	if cp.transitions[0]["status"] != "failed" {
		t.Errorf("transition status = %v, want failed", cp.transitions[0]["status"])
	}
	if reason, _ := cp.transitions[0]["failure_reason"].(string); !strings.Contains(reason, "caddy reload") {
		t.Errorf("failure_reason should mention caddy reload: %q", reason)
	}

	// The just-started green container must be torn down, not leaked.
	if !hasDockerRmForSite(runner.calls, "shop") {
		t.Errorf("expected docker rm -f site-shop-... after caddy reload failure; calls: %+v", runner.calls)
	}
}

func TestRunOnce_WriteCaddyfileFails_ReapsGreenContainer(t *testing.T) {
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

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()
	containerPort := mustPort(t, containerSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            failWriteFS{}, // WriteFile always errors
		Ports:         &fixedPorts{next: containerPort},
		HealthTimeout: 2 * time.Second,
	}

	had, err := e.RunOnce(context.Background(), State{})
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true even on writeCaddyfile failure")
	}

	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	if cp.transitions[0]["status"] != "failed" {
		t.Errorf("transition status = %v, want failed", cp.transitions[0]["status"])
	}
	if reason, _ := cp.transitions[0]["failure_reason"].(string); !strings.Contains(reason, "write caddyfile") {
		t.Errorf("failure_reason should mention write caddyfile: %q", reason)
	}

	if !hasDockerRmForSite(runner.calls, "shop") {
		t.Errorf("expected docker rm -f site-shop-... after writeCaddyfile failure; calls: %+v", runner.calls)
	}
}

// hasDockerRmForSite reports whether a `docker rm -f site-<slug>-...` call was
// issued (the green-container reaper on the Caddy-step failure branches).
func hasDockerRmForSite(calls []call, slug string) bool {
	for _, c := range calls {
		if c.name != "docker" || len(c.args) < 3 || c.args[0] != "rm" || c.args[1] != "-f" {
			continue
		}
		if strings.HasPrefix(c.args[2], "site-"+slug+"-") {
			return true
		}
	}
	return false
}

// failWriteFS is a FileSystem whose WriteFile always fails, exercising the
// writeCaddyfile-fail branch of RunOnce.
type failWriteFS struct{}

func (failWriteFS) WriteFile(path string, data []byte, perm uint32) error {
	return errors.New("disk full")
}

func (failWriteFS) ReadFile(path string) ([]byte, error) {
	return nil, fs.ErrNotExist
}

// When the atomic rename fails, OSFS.WriteFile must not strand the <path>.tmp
// turd on disk (a leftover .Caddyfile.tmp on every failed live-config write).
func TestOSFS_WriteFile_RenameFails_CleansUpTemp(t *testing.T) {
	dir := t.TempDir()
	// Make the destination path an existing directory so os.Rename(tmp, path)
	// fails (can't rename a file over a non-empty/existing directory).
	path := filepath.Join(dir, "Caddyfile")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatalf("mkdir dest: %v", err)
	}

	err := OSFS{}.WriteFile(path, []byte("hello"), 0o644)
	if err == nil {
		t.Fatalf("expected WriteFile to fail when rename target is a directory")
	}

	if _, statErr := os.Stat(path + ".tmp"); !os.IsNotExist(statErr) {
		t.Errorf("temp file %s was not cleaned up after rename failure (stat err: %v)", path+".tmp", statErr)
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

func TestMergeSite_PreservesStaticKindAndRoot(t *testing.T) {
	// A static site already live in state.LiveSites (charter D9) must survive a
	// reverse_proxy deploy of a DIFFERENT slug: mergeSite operates on whole
	// caddyfile.Site values, so Kind/Root ride through untouched and the
	// rendered Caddyfile keeps its file_server block.
	existing := []caddyfile.Site{
		{Slug: "flat", Domains: []string{"docs.com"}, Kind: caddyfile.KindStatic, Root: "/srv/flat/current"},
	}
	out := mergeSite(existing, caddyfile.Site{Slug: "app", Domains: []string{"app.com"}, Port: 7001})
	if len(out) != 2 {
		t.Fatalf("len = %d, want 2", len(out))
	}
	var static *caddyfile.Site
	for i := range out {
		if out[i].Slug == "flat" {
			static = &out[i]
		}
	}
	if static == nil {
		t.Fatal("static site dropped by mergeSite")
	}
	if static.Kind != caddyfile.KindStatic || static.Root != "/srv/flat/current" {
		t.Errorf("static Kind/Root not preserved: %+v", *static)
	}
	// And it renders as file_server, not reverse_proxy, alongside the proxied one.
	rendered := caddyfile.Render(caddyfile.Box{Sites: out})
	if !strings.Contains(rendered, "root * /srv/flat/current\n  file_server\n") {
		t.Errorf("static block missing after merge:\n%s", rendered)
	}
	if !strings.Contains(rendered, "reverse_proxy 127.0.0.1:7001") {
		t.Errorf("proxied block missing after merge:\n%s", rendered)
	}
}

func TestTLSModeForServing(t *testing.T) {
	// cf_proxied → internal (526-safe self-signed); every other value —
	// direct, empty, or an unrecognized string — fails safe to on_demand so an
	// unknown mode never silently produces a self-signed origin.
	cases := []struct {
		serving string
		want    string
	}{
		{ServingModeCFProxied, caddyfile.TLSModeInternal},
		{ServingModeDirect, caddyfile.TLSModeOnDemand},
		{"", caddyfile.TLSModeOnDemand},
		{"nonsense", caddyfile.TLSModeOnDemand},
	}
	for _, c := range cases {
		if got := tlsModeForServing(c.serving); got != c.want {
			t.Errorf("tlsModeForServing(%q) = %q, want %q", c.serving, got, c.want)
		}
	}
}

// deployAndReadCaddyfile walks a single claim→live cycle for site through the
// real Executor (fake runner/fs/ports) and returns the rendered Caddyfile — the
// end-to-end path that proves serving_mode threads into the rendered TLS block.
func deployAndReadCaddyfile(t *testing.T, site InlineSite) string {
	t.Helper()
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-12345678abcdef",
			SiteID:   "s-aabbccdd",
			Status:   "pushing",
			ImageTag: "site-shop-d-12345678",
			Site:     site,
		},
		epoch: 1,
	}}

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()
	containerPort := mustPort(t, containerSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	fs := newMapFS()
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		AskGateURL:    "https://cloud.barkpark.cloud/v1/tls/ask",
		HTTPClient:    srv.Client(),
		Runner:        &fakeRunner{},
		FS:            fs,
		Ports:         &fixedPorts{next: containerPort},
		HealthTimeout: 2 * time.Second,
	}
	if _, err := e.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	caddy, ok := fs.files["/etc/caddy/Caddyfile"]
	if !ok {
		t.Fatal("Caddyfile was not written")
	}
	return string(caddy)
}

func TestRunOnce_CFProxiedServingMode_RendersInternalTLS(t *testing.T) {
	// serving_mode=cf_proxied on the claim must thread through mergeSite into the
	// rendered TLS block: `tls internal`, never the on_demand cert block (which
	// behind the CF proxy is a 526 outage).
	caddy := deployAndReadCaddyfile(t, InlineSite{
		Slug:        "shop",
		Domains:     []string{"shop.example.com"},
		ServingMode: ServingModeCFProxied,
	})
	if !strings.Contains(caddy, "  tls internal\n") {
		t.Errorf("cf_proxied site must render `tls internal`:\n%s", caddy)
	}
	if strings.Contains(caddy, "  tls {\n    on_demand\n  }") {
		t.Errorf("cf_proxied site must NOT emit an on_demand cert block (526 outage):\n%s", caddy)
	}
	// A CF-fronted site also trusts the CF edge ranges for client-IP.
	if !strings.Contains(caddy, "trusted_proxies") {
		t.Errorf("cf_proxied (CF-fronted) box must emit trusted_proxies:\n%s", caddy)
	}
}

func TestRunOnce_DirectServingMode_StaysOnDemand(t *testing.T) {
	// Empty serving_mode (today's default) and an explicit "direct" both keep the
	// on_demand block — the pre-CF behaviour untouched. (Byte-identity of the
	// on_demand block across an explicit and zero-value TLSMode is proven at the
	// caddyfile layer; here the two deploys allocate different container ports, so
	// this asserts the mode behaviour, not the exact bytes.)
	empty := deployAndReadCaddyfile(t, InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}})
	direct := deployAndReadCaddyfile(t, InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}, ServingMode: ServingModeDirect})
	for name, caddy := range map[string]string{"empty": empty, "direct": direct} {
		if !strings.Contains(caddy, "  tls {\n    on_demand\n  }\n") {
			t.Errorf("%s serving_mode must keep the on_demand site block:\n%s", name, caddy)
		}
		if strings.Contains(caddy, "tls internal") {
			t.Errorf("%s serving_mode must NOT render tls internal:\n%s", name, caddy)
		}
		if strings.Contains(caddy, "trusted_proxies") {
			t.Errorf("%s serving_mode is not CF-fronted, must not emit trusted_proxies:\n%s", name, caddy)
		}
	}
}

// --- site-env-injection ------------------------------------------------------

// dockerRunCall returns the args of the `docker run` invocation, or nil.
func dockerRunCall(calls []call) []string {
	for _, c := range calls {
		if c.name == "docker" && len(c.args) > 0 && c.args[0] == "run" {
			return c.args
		}
	}
	return nil
}

// envDeploy walks one claim→live cycle with the given site env scripted on the
// CP (nil env + code 0 → the route 404s) and returns the fake runner.
func envDeploy(t *testing.T, arrange func(*scriptedCP)) *fakeRunner {
	t.Helper()
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-env12345678",
			SiteID:   "s-envaabbccdd",
			Status:   "pushing",
			ImageTag: "site-shop-d-env12345",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 1,
	}}
	arrange(cp)

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{}
	e := &Executor{
		ControlURL:    srv.URL,
		AgentToken:    "test-token",
		WorkerID:      "agent-1",
		CacheDir:      "/var/lib/barkpark-builder/images",
		CaddyfilePath: "/etc/caddy/Caddyfile",
		HTTPClient:    srv.Client(),
		Runner:        runner,
		FS:            newMapFS(),
		Ports:         &fixedPorts{next: mustPort(t, containerSrv.URL)},
		HealthTimeout: 2 * time.Second,
	}
	had, err := e.RunOnce(context.Background(), State{})
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}
	return runner
}

// The executor fetches the site env and injects each pair as `-e KEY=VAL` on
// the docker run, sorted by key, BEFORE the platform pairs — so the platform's
// PORT/HOSTNAME (last -e wins in docker) can never be overridden off the port
// Caddy proxies to.
func TestRunOnce_SiteEnv_InjectsDockerEnvPairs(t *testing.T) {
	runner := envDeploy(t, func(cp *scriptedCP) {
		cp.siteEnv = map[string]string{
			"BARKPARK_READ_TOKEN": "tok-secret-value",
			"API_BASE":            "https://api.example.com",
			"PORT":                "9999", // hostile: tries to repoint the container
		}
	})

	args := dockerRunCall(runner.calls)
	if args == nil {
		t.Fatalf("no docker run call: %+v", runner.calls)
	}
	joined := strings.Join(args, " ")

	// Sorted site pairs present.
	if !strings.Contains(joined,
		"-e API_BASE=https://api.example.com -e BARKPARK_READ_TOKEN=tok-secret-value -e PORT=9999") {
		t.Errorf("docker run missing sorted site -e pairs: %q", joined)
	}
	// Platform pairs still present and LAST — docker's last -e wins, so the
	// site's PORT=9999 loses to the platform's PORT=3000.
	sitePort := strings.Index(joined, "-e PORT=9999")
	platPort := strings.Index(joined, "-e PORT=3000")
	if platPort < 0 || !strings.Contains(joined, "-e HOSTNAME=0.0.0.0") {
		t.Fatalf("docker run lost the platform HOSTNAME/PORT pairs: %q", joined)
	}
	if sitePort > platPort {
		t.Errorf("site PORT must come BEFORE the platform PORT (last -e wins): %q", joined)
	}
}

// An empty blob (200 {env:{}}) and a control plane predating the route (404)
// both run env-less: exactly the two platform -e pairs, nothing more.
func TestRunOnce_SiteEnvEmptyOr404_RunsEnvless(t *testing.T) {
	cases := map[string]func(*scriptedCP){
		"empty blob": func(cp *scriptedCP) { cp.siteEnv = map[string]string{} },
		"route 404":  func(cp *scriptedCP) {}, // nil siteEnv → 404
	}
	for name, arrange := range cases {
		t.Run(name, func(t *testing.T) {
			runner := envDeploy(t, arrange)
			args := dockerRunCall(runner.calls)
			if args == nil {
				t.Fatalf("no docker run call: %+v", runner.calls)
			}
			var envs []string
			for i, a := range args {
				if a == "-e" && i+1 < len(args) {
					envs = append(envs, args[i+1])
				}
			}
			if len(envs) != 2 || envs[0] != "HOSTNAME=0.0.0.0" || envs[1] != "PORT=3000" {
				t.Errorf("env-less run must carry exactly the platform pairs, got %v", envs)
			}
		})
	}
}

// A 500 from the env route FAILS the deploy (transition failed, reason names
// the env fetch) — never a silent env-less container for a site that
// configured env. And no docker run was attempted at all.
func TestRunOnce_SiteEnvFetch500_TransitionsFailed(t *testing.T) {
	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-env500",
			SiteID:   "s-env500",
			Status:   "pushing",
			ImageTag: "site-shop-d-env500",
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 2,
	}}
	cp.siteEnvCode = http.StatusInternalServerError

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	runner := &fakeRunner{}
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
		t.Fatalf("expected had=true even on env-fetch failure")
	}
	if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "failed" {
		t.Fatalf("expected one failed transition, got %+v", cp.transitions)
	}
	if reason, _ := cp.transitions[0]["failure_reason"].(string); !strings.Contains(reason, "site env") {
		t.Errorf("failure_reason should name the env fetch: %q", reason)
	}
	if args := dockerRunCall(runner.calls); args != nil {
		t.Errorf("no container may start when the env fetch failed: %v", args)
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

// TestHTTPNilFallbackHasTimeout proves the nil-HTTPClient fallback is
// Timeout-bearing (not http.DefaultClient, whose Timeout is 0 == no
// deadline) — a hung control-plane connection must not freeze the
// claim/transition loop forever with no crash and no log.
func TestHTTPNilFallbackHasTimeout(t *testing.T) {
	e := &Executor{}
	c := e.http()
	if c.Timeout == 0 {
		t.Fatal("http() with nil HTTPClient has Timeout == 0, want a non-zero deadline")
	}
}

// TestRunOnceTimesOutAgainstHangingServer proves a hung control-plane
// connection surfaces as a timeout error from a single RunOnce iteration
// rather than blocking forever. It injects a client with a short timeout
// (rather than waiting out the real 30s fallback) against a server that
// never writes a response, so the test itself stays fast.
func TestRunOnceTimesOutAgainstHangingServer(t *testing.T) {
	const clientTimeout = 50 * time.Millisecond
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/agent/deployments/claim", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * clientTimeout) // outlast the client's timeout, then respond
		w.WriteHeader(http.StatusOK)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	e := &Executor{
		ControlURL: srv.URL,
		AgentToken: "test-token",
		WorkerID:   "agent-1",
		HTTPClient: &http.Client{Timeout: clientTimeout},
		Runner:     &fakeRunner{},
		FS:         newMapFS(),
		Ports:      &fixedPorts{next: 7001},
	}

	start := time.Now()
	_, err := e.RunOnce(context.Background(), State{})
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("RunOnce returned nil against a hanging server, want a timeout error")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("RunOnce took %s to return an error, want it to return promptly on client timeout", elapsed)
	}
}

// TestExecuteDeploy_MaliciousImageTagLandsAsOneLiteralArgv is the RCE
// regression: ImageTag is decoded RAW from the control-plane claim JSON, and
// the old `docker load` path ran `sh -c "docker load -i %q"` — Go's %q does NOT
// neutralize `$(...)`/backticks inside a shell, so a hostile tag executed
// arbitrary code (a probe wrote /tmp/pwned). The fix runs a fixed argv straight
// to docker (ExecRunner.Run == exec.CommandContext, raw execve, no shell), so
// the whole payload must arrive as a SINGLE literal filename argument — never
// split, never expanded.
func TestExecuteDeploy_MaliciousImageTagLandsAsOneLiteralArgv(t *testing.T) {
	const evilTag = "site-shop-$(touch /tmp/pwned)-`id`"

	cp := newCP(t)
	cp.pending = []claimReply{{
		deployment: Deployment{
			ID:       "d-evil0001abcdef",
			SiteID:   "s-evil0001",
			Status:   "pushing",
			ImageTag: evilTag,
			Site:     InlineSite{Slug: "shop", Domains: []string{"shop.example.com"}},
		},
		epoch: 1,
	}}

	containerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer containerSrv.Close()
	containerPort := mustPort(t, containerSrv.URL)

	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

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
		FS:            newMapFS(),
		Ports:         &fixedPorts{next: containerPort},
		HealthTimeout: 2 * time.Second,
	}

	if _, err := e.RunOnce(context.Background(), State{}); err != nil {
		t.Fatalf("err: %v", err)
	}

	if len(runner.calls) == 0 {
		t.Fatalf("no runner calls recorded")
	}
	load := runner.calls[0]
	if load.name != "docker" {
		t.Fatalf("docker load ran via %q, want a direct \"docker\" exec (no shell): %+v", load.name, load)
	}
	// Fixed argv: exactly ["load", "-i", "<cacheDir>/<tag>.tar"] — the payload is
	// the trailing filename and NOTHING else, one element.
	want := []string{"load", "-i", "/var/lib/barkpark-builder/images/" + evilTag + ".tar"}
	if len(load.args) != len(want) {
		t.Fatalf("docker load argv = %#v, want %#v", load.args, want)
	}
	for i := range want {
		if load.args[i] != want[i] {
			t.Fatalf("docker load argv[%d] = %q, want %q (full: %#v)", i, load.args[i], want[i], load.args)
		}
	}
	// Belt-and-braces: the injection metacharacters survive verbatim inside the
	// single filename argument — proof they were passed as data, not a command.
	if !strings.Contains(load.args[2], "$(touch /tmp/pwned)") || !strings.Contains(load.args[2], "`id`") {
		t.Fatalf("payload was altered in transit, expected it intact as a literal: %q", load.args[2])
	}
}
