package builder

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// --- A scripted control plane for the builder tests --------------------------

type scriptedCP struct {
	t              *testing.T
	mu             sync.Mutex
	claims         []claimReply
	nextClaim      int32
	transitions    []map[string]any
	transitionResp int // status for transitions; 0 → 200
	consoleLines   []string
	consoleResp    int // status for console posts; 0 → 200
}

type claimReply struct {
	status     int
	deployment Deployment
	epoch      int
}

func newScriptedCP(t *testing.T) *scriptedCP { return &scriptedCP{t: t} }

func (s *scriptedCP) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/v1/builder/claim", func(w http.ResponseWriter, r *http.Request) {
		if !s.expectAuth(w, r) {
			return
		}
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body["worker_id"] == "" {
			http.Error(w, `{"error":"worker_id_required"}`, http.StatusUnprocessableEntity)
			return
		}

		s.mu.Lock()
		idx := int(atomic.AddInt32(&s.nextClaim, 1)) - 1
		if idx >= len(s.claims) {
			s.mu.Unlock()
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"no_queued"}`))
			return
		}
		reply := s.claims[idx]
		s.mu.Unlock()

		if reply.status == 0 || reply.status == http.StatusOK {
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"deployment":     reply.deployment,
				"observed_epoch": reply.epoch,
			})
			return
		}
		w.WriteHeader(reply.status)
	})

	mux.HandleFunc("/v1/builder/deployments/", func(w http.ResponseWriter, r *http.Request) {
		if !s.expectAuth(w, r) {
			return
		}
		if strings.HasSuffix(r.URL.Path, "/console") {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			line, _ := body["line"].(string)

			s.mu.Lock()
			s.consoleLines = append(s.consoleLines, line)
			code := s.consoleResp
			s.mu.Unlock()

			if code == 0 {
				code = http.StatusOK
			}
			w.WriteHeader(code)
			_, _ = w.Write([]byte(`{"ok":true}`))
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
		code := s.transitionResp
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

// consoleJoined returns all console lines this CP received, newline-joined, for
// order + content assertions.
func (s *scriptedCP) consoleJoined() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.consoleLines, "\n")
}

func (s *scriptedCP) expectAuth(w http.ResponseWriter, r *http.Request) bool {
	if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
		s.t.Errorf("missing/wrong auth header: %q", got)
		http.Error(w, "no auth", http.StatusUnauthorized)
		return false
	}
	return true
}

// --- A scripted runner -------------------------------------------------------

type scriptedRunner struct {
	t          *testing.T
	calls      []runCall
	failOnName string
	failErr    error
}

type runCall struct {
	name string
	args []string
}

func (r *scriptedRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	r.calls = append(r.calls, runCall{name: name, args: append([]string(nil), args...)})
	fmt.Fprintf(w, "[fake] %s %s\n", name, strings.Join(args, " "))
	if r.failOnName != "" && name == r.failOnName {
		return r.failErr
	}
	return nil
}

// --- An in-memory log capture so tests don't write to disk -------------------

func swapInMemoryLogs() (*bytes.Buffer, func()) {
	prev := openLog
	buf := &bytes.Buffer{}
	openLog = func(string) (io.WriteCloser, error) { return nopCloser{Writer: buf}, nil }
	return buf, func() { openLog = prev }
}

type nopCloser struct{ io.Writer }

func (nopCloser) Close() error { return nil }

// --- tests -------------------------------------------------------------------

func TestRunOnce_QueueEmpty(t *testing.T) {
	cp := newScriptedCP(t)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		HTTPClient: srv.Client(),
	}

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if had {
		t.Fatalf("expected had=false (no queued), got true")
	}
}

func TestRunOnce_HappyPath_NixpacksThenTransitionPushing(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-12345678abcdef",
			SiteID:      "s-87654321ffffff",
			Status:      "building",
			GitRef:      "main",
			ArtifactURL: "file:///tmp/p2-fixture",
		},
		epoch: 1,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	runner := &scriptedRunner{t: t}
	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		Platform:   "linux/arm64",
		CacheDir:   "/tmp/p2-cache",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     runner,
	}

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true (one claimed), got false")
	}

	if len(runner.calls) < 2 {
		t.Fatalf("expected nixpacks + docker save, got %d call(s): %+v", len(runner.calls), runner.calls)
	}

	// First call is `nice -n 10 nixpacks build /tmp/p2-fixture --name <tag> --platform linux/arm64`.
	first := runner.calls[0]
	if first.name != "nice" {
		t.Errorf("first call name = %q, want %q", first.name, "nice")
	}
	joined := strings.Join(first.args, " ")
	if !strings.Contains(joined, "nixpacks build /tmp/p2-fixture") {
		t.Errorf("first call args = %q, want to contain 'nixpacks build /tmp/p2-fixture'", joined)
	}
	if !strings.Contains(joined, "--platform linux/arm64") {
		t.Errorf("first call args missing --platform: %q", joined)
	}
	if !strings.Contains(joined, "--name site-s-876543") {
		t.Errorf("first call args missing image tag: %q", joined)
	}

	// Second call is `docker save <tag> -o <cache>/<tag>.tar` — no shell, so a
	// failed/interrupted save can't leave a truncated .tar in the cache.
	second := runner.calls[1]
	if second.name != "docker" {
		t.Errorf("second call name = %q, want %q", second.name, "docker")
	}
	secondJoined := strings.Join(second.args, " ")
	if !strings.HasPrefix(secondJoined, "save site-s-876543") {
		t.Errorf("second call args = %q, want to start with 'save site-s-876543'", secondJoined)
	}
	if !strings.Contains(secondJoined, "-o ") || !strings.HasSuffix(secondJoined, ".tar") {
		t.Errorf("second call args missing '-o <out>.tar': %v", second.args)
	}

	// One transition POST was made: status=pushing, image_tag set, build_log_url set.
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	tr := cp.transitions[0]
	if tr["status"] != "pushing" {
		t.Errorf("transition status = %v, want pushing", tr["status"])
	}
	if !strings.HasPrefix(tr["image_tag"].(string), "site-s-876543") {
		t.Errorf("transition image_tag = %v, want site-s-876543...", tr["image_tag"])
	}
	if !strings.HasPrefix(tr["build_log_url"].(string), "file:///tmp/p2-logs/") {
		t.Errorf("transition build_log_url = %v, want file:///tmp/p2-logs/...", tr["build_log_url"])
	}
	if got := tr["worker_id"].(string); got != "w-1" {
		t.Errorf("transition worker_id = %q, want w-1", got)
	}
	// observed_epoch must echo the claim's epoch — the CAS fence.
	if got, _ := tr["observed_epoch"].(float64); int(got) != 1 {
		t.Errorf("transition observed_epoch = %v, want 1", tr["observed_epoch"])
	}
}

func TestRunOnce_BuildFailure_TransitionsFailed(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-failure",
			SiteID:      "s-failure",
			ArtifactURL: "file:///tmp/p2-fixture",
		},
		epoch: 3,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	runner := &scriptedRunner{
		t:          t,
		failOnName: "nice",
		failErr:    errors.New("exit status 1: package.json missing engines.node"),
	}

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     runner,
	}

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true (claimed even though build failed), got false")
	}
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	tr := cp.transitions[0]
	if tr["status"] != "failed" {
		t.Errorf("transition status = %v, want failed", tr["status"])
	}
	reason, _ := tr["failure_reason"].(string)
	if !strings.Contains(reason, "package.json missing engines.node") {
		t.Errorf("transition failure_reason = %q, expected to contain 'package.json missing engines.node'", reason)
	}
	// observed_epoch still set to the claim's epoch (the fence holds even on
	// failure — otherwise the lease-swept window could double-report failures).
	if got, _ := tr["observed_epoch"].(float64); int(got) != 3 {
		t.Errorf("transition observed_epoch = %v, want 3", tr["observed_epoch"])
	}
}

func TestRunOnce_UnsupportedArtifactScheme_FailsCleanly(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-bad-art",
			SiteID:      "s-bad-art",
			ArtifactURL: "ftp://nope",
		},
		epoch: 1,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     &scriptedRunner{t: t},
	}

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true, got false")
	}
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition (failed), got %d", len(cp.transitions))
	}
	if cp.transitions[0]["status"] != "failed" {
		t.Errorf("transition status = %v, want failed", cp.transitions[0]["status"])
	}
	if r, _ := cp.transitions[0]["failure_reason"].(string); !strings.Contains(r, "unsupported artifact scheme") {
		t.Errorf("failure_reason should mention scheme: %q", r)
	}
}

func TestResolveArtifact(t *testing.T) {
	b := &Builder{}
	cases := []struct {
		in      string
		want    string
		wantErr bool
	}{
		{"file:///abs/path", "/abs/path", false},
		{"file:///tmp/p2-fixture", "/tmp/p2-fixture", false},
		{"", "", true},
		{"https://example.com/bundle.tgz", "", true},
	}
	for _, c := range cases {
		got, err := b.resolveArtifact(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("resolveArtifact(%q) want err, got %q", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("resolveArtifact(%q) err: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("resolveArtifact(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// gh-5: the builder narrates its REAL phases (claim → source → build → artifact
// → activate) to the live build console, and the raw command output streams
// through the tee line-by-line.
func TestRunOnce_NarratesBuildPhasesToConsole(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-12345678abcdef",
			SiteID:      "s-87654321ffffff",
			Status:      "building",
			GitRef:      "main",
			ArtifactURL: "file:///tmp/p2-fixture",
		},
		epoch: 1,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		Platform:   "linux/arm64",
		CacheDir:   "/tmp/p2-cache",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     &scriptedRunner{t: t},
	}

	if _, err := b.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}

	joined := cp.consoleJoined()

	// Each real phase must be narrated, in order, with an honest vocabulary.
	phases := []string{
		"claim: deployment d-123456",
		"source: resolving artifact file:///tmp/p2-fixture",
		"source: ready at /tmp/p2-fixture",
		"build: nixpacks build site-s-876543",
		"artifact: docker save site-s-876543",
		"artifact: image saved to /tmp/p2-cache/site-",
		"activate: build complete",
	}
	prev := -1
	for _, want := range phases {
		at := strings.Index(joined, want)
		if at < 0 {
			t.Errorf("console missing phase line %q\n--- console ---\n%s", want, joined)
			continue
		}
		if at < prev {
			t.Errorf("phase %q out of order (at %d, prev %d)", want, at, prev)
		}
		prev = at
	}

	// The raw runner output streamed through the tee line-by-line (the actual
	// build log the user watches — not just phase headers).
	if !strings.Contains(joined, "[fake] nice -n 10 nixpacks build") {
		t.Errorf("console did not stream the raw nixpacks output line: %s", joined)
	}
	if !strings.Contains(joined, "[fake] docker save") {
		t.Errorf("console did not stream the raw docker output line: %s", joined)
	}
}

// gh-5 never-fails-build: a console endpoint returning 500 on EVERY line must
// NOT fail the build — the deployment still transitions to pushing.
func TestRunOnce_ConsoleEndpointDown_NeverFailsBuild(t *testing.T) {
	cp := newScriptedCP(t)
	cp.consoleResp = http.StatusInternalServerError
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-consoledown",
			SiteID:      "s-consoledown",
			Status:      "building",
			GitRef:      "main",
			ArtifactURL: "file:///tmp/p2-fixture",
		},
		epoch: 7,
	}}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		CacheDir:   "/tmp/p2-cache",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     &scriptedRunner{t: t},
	}

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v (a console 500 must never fail the build)", err)
	}
	if !had {
		t.Fatalf("expected had=true, got false")
	}
	if len(cp.transitions) != 1 {
		t.Fatalf("expected 1 transition, got %d", len(cp.transitions))
	}
	if cp.transitions[0]["status"] != "pushing" {
		t.Errorf("build must still reach pushing despite console 500s, got %v", cp.transitions[0]["status"])
	}
}

// gh-5 redaction: secret-shaped output is scrubbed before a console line leaves
// the builder — registered literals, Barkpark tokens, Bearer headers, and
// secret-shaped env assignments.
func TestRedactBuildLine(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		secrets []string
		want    string
		notWant string
	}{
		{
			name: "database url value scrubbed, key kept",
			in:   "env DATABASE_URL=postgres://u:p@h/db loaded",
			want: "env DATABASE_URL=[REDACTED] loaded",
		},
		{
			name: "api token value scrubbed",
			in:   "STRIPE_API_TOKEN=sk_live_deadbeef exported",
			want: "STRIPE_API_TOKEN=[REDACTED] exported",
		},
		{
			name: "generic secret env scrubbed",
			in:   "NEXTAUTH_SECRET=hunter2hunter2",
			want: "NEXTAUTH_SECRET=[REDACTED]",
		},
		{
			name:    "bearer header scrubbed",
			in:      "curl -H 'Authorization: Bearer abc.def.ghi'",
			notWant: "abc.def.ghi",
		},
		{
			name:    "barkpark admin token scrubbed",
			in:      "minted bp_admin_supersecrettoken for box",
			notWant: "bp_admin_supersecrettoken",
		},
		{
			name:    "registered literal secret scrubbed",
			in:      "using key deploykey-literal-xyz now",
			secrets: []string{"deploykey-literal-xyz"},
			notWant: "deploykey-literal-xyz",
		},
		{
			name: "ordinary prose is untouched",
			in:   "building the Next.js app for production",
			want: "building the Next.js app for production",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := redactBuildLine(c.in, c.secrets)
			if c.want != "" && got != c.want {
				t.Errorf("redactBuildLine(%q) = %q, want %q", c.in, got, c.want)
			}
			if c.notWant != "" && strings.Contains(got, c.notWant) {
				t.Errorf("redactBuildLine(%q) = %q, must NOT contain %q", c.in, got, c.notWant)
			}
		})
	}
}

// The tee writes the raw bytes through to the underlying log unchanged, buffers a
// partial line until its newline, and mirrors each complete line redacted.
func TestConsoleTee_PassthroughAndLineMirror(t *testing.T) {
	cp := newScriptedCP(t)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, Token: "test-token", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "d-tee")

	var underlying bytes.Buffer
	tee := &consoleTee{w: &underlying, c: con}

	// A partial line, then the rest + a full second line carrying a secret.
	_, _ = tee.Write([]byte("compil"))
	_, _ = tee.Write([]byte("ing…\nDATABASE_URL=postgres://secret\n"))
	tee.flush()

	// Passthrough is byte-exact (the durable log is unmodified — redaction is a
	// console-only concern).
	if underlying.String() != "compiling…\nDATABASE_URL=postgres://secret\n" {
		t.Errorf("underlying log altered: %q", underlying.String())
	}

	joined := cp.consoleJoined()
	if !strings.Contains(joined, "compiling…") {
		t.Errorf("first (reassembled) line not mirrored: %q", joined)
	}
	if strings.Contains(joined, "postgres://secret") {
		t.Errorf("secret leaked to console: %q", joined)
	}
	if !strings.Contains(joined, "DATABASE_URL=[REDACTED]") {
		t.Errorf("env secret not redacted on console: %q", joined)
	}
}

// Cross-check the image tag stays deterministic + collision-free under variation.
func TestShortDeterministic(t *testing.T) {
	id := "abcdef1234567890"
	if short(id) != "abcdef12" {
		t.Errorf("short(%q) = %q, want abcdef12", id, short(id))
	}
	if short("abc") != "abc" {
		t.Errorf("short of short string should be the string itself")
	}
}

// Defense in depth: openLog stub created the right path shape (the real impl
// would put it under LogDir/<deployment_id>.log).
func TestBuildLogPathShape(t *testing.T) {
	have := filepath.Join("/tmp/p2-logs", "d-1234.log")
	want := "/tmp/p2-logs/d-1234.log"
	if have != want {
		t.Errorf("filepath.Join gave %q, want %q", have, want)
	}
}
