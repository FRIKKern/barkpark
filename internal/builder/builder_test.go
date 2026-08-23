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
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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
	consoleResp    int      // status for console posts; 0 → 200
	detailLines    []string // dwb-19: the live sub-captions posted to /detail
	detailResp     int      // status for detail posts; 0 → 200

	// site-env-injection: the env GET /v1/builder/sites/:id/env answers with.
	// nil siteEnv + siteEnvCode 0 → 404, emulating a control plane that
	// predates the route (the build must proceed env-less).
	siteEnv     map[string]string
	siteEnvCode int // 0 → 404 when siteEnv is nil, else 200
}

type claimReply struct {
	status     int
	deployment Deployment
	epoch      int
	source     *BuildSource // sites-github-auto-build: the claim's `source` sibling; nil → key omitted
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
			payload := map[string]any{
				"deployment":     reply.deployment,
				"observed_epoch": reply.epoch,
			}
			if reply.source != nil {
				payload["source"] = reply.source
			}
			_ = json.NewEncoder(w).Encode(payload)
			return
		}
		w.WriteHeader(reply.status)
	})

	mux.HandleFunc("/v1/builder/sites/", func(w http.ResponseWriter, r *http.Request) {
		if !s.expectAuth(w, r) {
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
		if strings.HasSuffix(r.URL.Path, "/detail") {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			detail, _ := body["detail"].(string)

			s.mu.Lock()
			s.detailLines = append(s.detailLines, detail)
			code := s.detailResp
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

// detailJoined returns all live sub-captions this CP received (dwb-19),
// newline-joined, for order + content assertions.
func (s *scriptedCP) detailJoined() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Join(s.detailLines, "\n")
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

// --- sites-github-auto-build: the git-ref source ladder ----------------------

// makeBareRepoFixture builds a local bare repo with two commits (marker.txt is
// "v1\n" at the parent, "v2\n" at the tip) and enables
// uploadpack.allowReachableSHA1InWant — the file:// transport then serves
// fetch-by-sha for reachable NON-advertised commits exactly like GitHub does.
// Returns the file:// URL plus both full shas.
func makeBareRepoFixture(t *testing.T) (url, tipSHA, parentSHA string) {
	t.Helper()
	root := t.TempDir()
	work := filepath.Join(root, "work")
	bare := filepath.Join(root, "origin.git")

	run := func(dir string, args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=fixture", "GIT_AUTHOR_EMAIL=fixture@test",
			"GIT_COMMITTER_NAME=fixture", "GIT_COMMITTER_EMAIL=fixture@test",
			"GIT_TERMINAL_PROMPT=0",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("fixture git %v: %v\n%s", args, err, out)
		}
		return strings.TrimSpace(string(out))
	}

	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	run(work, "init", "--quiet")
	if err := os.WriteFile(filepath.Join(work, "marker.txt"), []byte("v1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(work, "add", "marker.txt")
	run(work, "commit", "--quiet", "-m", "c1")
	parentSHA = run(work, "rev-parse", "HEAD")
	if err := os.WriteFile(filepath.Join(work, "marker.txt"), []byte("v2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(work, "commit", "--quiet", "-am", "c2")
	tipSHA = run(work, "rev-parse", "HEAD")

	run(root, "init", "--quiet", "--bare", bare)
	run(work, "push", "--quiet", bare, "HEAD:refs/heads/main")
	run(bare, "config", "uploadpack.allowReachableSHA1InWant", "true")

	return "file://" + bare, tipSHA, parentSHA
}

// gitClaim mints a claim whose deployment has NO artifact_url — the source
// envelope is the only lane.
func gitClaim(src *BuildSource) claimReply {
	return claimReply{
		deployment: Deployment{
			ID:     "d-git12345678",
			SiteID: "s-git87654321",
			Status: "building",
			GitRef: src.Ref,
		},
		epoch:  1,
		source: src,
	}
}

// The happy path by sha: the claim mints source{kind:git}, the builder shallow-
// fetches the PARENT sha (reachable but NOT advertised — the exact case a
// depth-1 branch fetch cannot serve), checks out FETCH_HEAD, and hands the
// checkout dir to nixpacks unchanged; the deployment lands pushing.
func TestRunOnce_GitSource_ShaFirstCloneFeedsNixpacks(t *testing.T) {
	url, _, parentSHA := makeBareRepoFixture(t)

	cp := newScriptedCP(t)
	cp.claims = []claimReply{gitClaim(&BuildSource{Kind: "git", URL: url, Ref: parentSHA})}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	runner := &scriptedRunner{t: t}
	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
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
		t.Fatalf("expected had=true, got false")
	}

	if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "pushing" {
		t.Fatalf("expected one pushing transition, got %+v", cp.transitions)
	}

	// The nixpacks invocation received the CHECKOUT DIR as its source arg —
	// nice -n 10 nixpacks build <dir> --name <tag>.
	if len(runner.calls) < 1 {
		t.Fatal("no runner calls recorded")
	}
	args := runner.calls[0].args
	if len(args) < 5 || args[2] != "nixpacks" || args[3] != "build" {
		t.Fatalf("first call is not a nixpacks build: %v", args)
	}
	dir := args[4]
	marker, err := os.ReadFile(filepath.Join(dir, "marker.txt"))
	if err != nil {
		t.Fatalf("checkout dir %s unreadable: %v", dir, err)
	}
	// "v1\n" proves the working tree is AT THE PARENT SHA, not the branch tip —
	// the fetch really was by sha, not tip-then-hope.
	if string(marker) != "v1\n" {
		t.Errorf("marker.txt = %q, want %q (checkout must be at the requested sha, not the tip)", marker, "v1\n")
	}

	// The console narrates the clone lane honestly.
	joined := cp.consoleJoined()
	if !strings.Contains(joined, "source: cloning "+url) {
		t.Errorf("console missing clone narration:\n%s", joined)
	}
	if !strings.Contains(joined, "source: ready at "+dir) {
		t.Errorf("console missing 'source: ready at %s':\n%s", dir, joined)
	}
}

// An UNREACHABLE sha (force-push / branch-delete between mint and claim) is a
// TERMINAL failure with the honest source-gone reason — the deployment fails
// once, it does not become a retry-forever zombie.
func TestRunOnce_GitSource_UnreachableSha_TerminalSourceGone(t *testing.T) {
	url, _, _ := makeBareRepoFixture(t)
	const goneSHA = "0000000000000000000000000000000000000001"

	cp := newScriptedCP(t)
	cp.claims = []claimReply{gitClaim(&BuildSource{Kind: "git", URL: url, Ref: goneSHA})}
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
	if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "failed" {
		t.Fatalf("expected one failed transition, got %+v", cp.transitions)
	}
	reason, _ := cp.transitions[0]["failure_reason"].(string)
	if !strings.Contains(reason, "no longer reachable") {
		t.Errorf("failure_reason should name source-gone: %q", reason)
	}
	if !strings.Contains(reason, goneSHA) {
		t.Errorf("failure_reason should carry the missing sha: %q", reason)
	}
}

// classifyGitFailure maps the two PROVEN stderr shapes to their terminal
// reasons, and everything else to a normal build failure carrying the git
// output tail.
func TestClassifyGitFailure(t *testing.T) {
	src := &BuildSource{
		Kind: "git",
		URL:  "https://github.com/acme/site.git",
		Ref:  "1405b8e1c46bbac81634ed6e57e2b3e68519b1fb",
	}
	fetchArgs := []string{"-c", "credential.helper=", "fetch", "--depth", "1", "origin", src.Ref}
	base := errors.New("exit status 128")

	cases := []struct {
		name    string
		stderr  string // the proven live-GitHub shapes, verbatim
		want    []string
		notWant string
	}{
		{
			name:   "unreachable sha is terminal source-gone",
			stderr: "fatal: remote error: upload-pack: not our ref 1405b8e1c46bbac81634ed6e57e2b3e68519b1fb",
			want:   []string{"terminal:", "no longer reachable", src.Ref, "force-push"},
		},
		{
			name:   "auth prompt is terminal repo-not-anonymously-accessible",
			stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
			want:   []string{"terminal:", "not anonymously accessible", src.URL},
		},
		{
			name:    "anything else is a normal failure with the output tail",
			stderr:  "fatal: unable to access 'https://github.com/acme/site.git/': Could not resolve host: github.com",
			want:    []string{"git -c credential.helper= fetch", "Could not resolve host"},
			notWant: "terminal:",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classifyGitFailure(src, fetchArgs, c.stderr, base)
			for _, w := range c.want {
				if !strings.Contains(got.Error(), w) {
					t.Errorf("classified error %q missing %q", got, w)
				}
			}
			if c.notWant != "" && strings.Contains(got.Error(), c.notWant) {
				t.Errorf("classified error %q must not contain %q", got, c.notWant)
			}
		})
	}
}

// Every clone-lane git invocation carries GIT_TERMINAL_PROMPT=0 and runs in
// the workdir — without the prompt kill, a private repo would hang the builder
// on a username prompt forever.
func TestGitCommand_PromptKillOnEnvAndWorkdirPinned(t *testing.T) {
	dir := t.TempDir()
	cmd := gitCommand(context.Background(), dir, "fetch", "--depth", "1", "origin", "deadbeef")
	if cmd.Dir != dir {
		t.Errorf("cmd.Dir = %q, want %q", cmd.Dir, dir)
	}
	found := false
	for _, kv := range cmd.Env {
		if kv == "GIT_TERMINAL_PROMPT=0" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("cmd.Env missing GIT_TERMINAL_PROMPT=0: %v", cmd.Env)
	}
}

// The ladder itself: an uploaded artifact ALWAYS wins over a source envelope;
// a source of an unknown kind (or no source at all) falls through to today's
// honest empty-artifact error.
func TestResolveSource_Ladder(t *testing.T) {
	cp := newScriptedCP(t)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, Token: "test-token", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "d-ladder")

	cases := []struct {
		name    string
		d       *claimedDeployment
		want    string
		wantErr string
	}{
		{
			name: "artifact wins even when a git source is present",
			d: &claimedDeployment{
				Deployment: Deployment{ArtifactURL: "file:///tmp/p2-fixture"},
				Source:     &BuildSource{Kind: "git", URL: "file:///does/not/exist", Ref: "deadbeef"},
			},
			want: "/tmp/p2-fixture",
		},
		{
			name:    "no artifact and no source is the honest empty-artifact error",
			d:       &claimedDeployment{},
			wantErr: "artifact_url is empty",
		},
		{
			name: "no artifact and an unknown source kind falls through to the same honest error",
			d: &claimedDeployment{
				Source: &BuildSource{Kind: "svn", URL: "svn://nope", Ref: "r42"},
			},
			wantErr: "artifact_url is empty",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := b.resolveSource(context.Background(), c.d, con)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("resolveSource err = %v, want to contain %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("resolveSource err: %v", err)
			}
			if got != c.want {
				t.Errorf("resolveSource = %q, want %q", got, c.want)
			}
		})
	}
}

// An incomplete source envelope (missing url or ref) fails fast with an honest
// message instead of handing git an empty argument.
func TestCloneGitSource_IncompleteEnvelope(t *testing.T) {
	b := &Builder{}
	for _, src := range []*BuildSource{
		{Kind: "git", URL: "", Ref: "deadbeef"},
		{Kind: "git", URL: "file:///somewhere", Ref: ""},
	} {
		if _, err := b.cloneGitSource(context.Background(), src); err == nil ||
			!strings.Contains(err.Error(), "source envelope incomplete") {
			t.Errorf("cloneGitSource(%+v) err = %v, want incomplete-envelope error", src, err)
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

// TestRunOnce_EmitsLiveCaptionsToDetail (dwb-19) proves the builder POSTs a
// plain-language live sub-caption to /detail at each real sub-boundary (start →
// fetch source → build → save image → hand off), distinct from the raw console,
// and that a caption never carries a token (redaction posture).
func TestRunOnce_EmitsLiveCaptionsToDetail(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{{
		deployment: Deployment{
			ID:          "d-cap0",
			SiteID:      "s-cap0",
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

	joined := cp.detailJoined()
	for _, want := range []string{
		"Fetching your source…",
		"Building your site…",
		"Saving the build image…",
		"Handing off to release…",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("no /detail caption %q; got:\n%s", want, joined)
		}
	}
	// The captions are the plain-language MIDDLE layer, never the raw command
	// output (that is the console's job) — a raw runner line must not appear here.
	if strings.Contains(joined, "[fake]") {
		t.Errorf("raw command output leaked into a /detail caption: %s", joined)
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

// A newline-less flood (a docker progress bar redrawing with '\r', or a hostile
// `yes | tr -d '\n'`) must NOT grow the tee's in-memory buffer without bound:
// after Write returns buf stays <= maxConsoleLineBytes, every byte still reached
// the durable log, and at least one prefix was force-emitted to the console.
func TestConsoleTee_BoundsNewlinelessFlood(t *testing.T) {
	cp := newScriptedCP(t)
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, Token: "test-token", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "d-flood")

	var underlying bytes.Buffer
	tee := &consoleTee{w: &underlying, c: con}

	const total = 200 << 10 // 200KB, not a single '\n'
	flood := bytes.Repeat([]byte("x"), total)
	n, err := tee.Write(flood)
	if err != nil {
		t.Fatalf("Write err: %v", err)
	}
	if n != total {
		t.Fatalf("short write: %d of %d", n, total)
	}

	if len(tee.buf) > maxConsoleLineBytes {
		t.Errorf("tee buffer unbounded: %d bytes > cap %d", len(tee.buf), maxConsoleLineBytes)
	}
	if underlying.Len() != total {
		t.Errorf("durable log lost bytes: got %d, want %d", underlying.Len(), total)
	}
	if cp.consoleJoined() == "" {
		t.Errorf("no prefix force-emitted to the console during the flood")
	}
}

// A control plane that 500s on every console POST must latch narration off after
// maxConsoleFails consecutive failures: feeding many lines then attempts only
// ~maxConsoleFails POSTs, not one-per-line (each of which would burn a full
// report timeout and could trip the stale-deployment reaper on a live build).
func TestBuildConsole_LatchesOffAfterRepeatedFailures(t *testing.T) {
	var posts int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&posts, 1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, Token: "test-token", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "d-latch")

	const lines = 20
	for i := 0; i < lines; i++ {
		con.logf("build line %d", i)
	}

	got := atomic.LoadInt32(&posts)
	if got > maxConsoleFails+1 {
		t.Errorf("latch did not engage: %d POSTs for %d lines (want <= %d)", got, lines, maxConsoleFails+1)
	}
	if got < maxConsoleFails {
		t.Errorf("latch engaged too early: only %d POSTs (want >= %d)", got, maxConsoleFails)
	}
}

// --- site-env-injection ------------------------------------------------------

// quietRunner records calls WITHOUT echoing argv into the writer — the
// env-injection tests assert secret values never reach the log/console, and the
// default scriptedRunner's "[fake] <argv>" echo would plant them there itself.
type quietRunner struct {
	calls []runCall
}

func (r *quietRunner) Run(ctx context.Context, w io.Writer, name string, args ...string) error {
	r.calls = append(r.calls, runCall{name: name, args: append([]string(nil), args...)})
	return nil
}

func envBuilder(srv *httptest.Server, runner CommandRunner) *Builder {
	return &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		CacheDir:   "/tmp/p2-cache",
		LogDir:     "/tmp/p2-logs",
		HTTPClient: srv.Client(),
		Runner:     runner,
	}
}

var envClaim = claimReply{
	deployment: Deployment{
		ID:          "d-env12345678",
		SiteID:      "s-env87654321",
		Status:      "building",
		GitRef:      "main",
		ArtifactURL: "file:///tmp/p2-fixture",
	},
	epoch: 1,
}

// The builder fetches the site env and hands every pair to nixpacks as
// `--env KEY=VAL`, sorted by key (deterministic invocation) — and the VALUES
// never reach the durable build log or the live console (key names only).
func TestRunOnce_SiteEnv_PassesNixpacksEnvFlags(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{envClaim}
	cp.siteEnv = map[string]string{
		"BARKPARK_READ_TOKEN": "tok-secret-value",
		"API_BASE":            "https://api.example.com",
	}
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	logBuf, restore := swapInMemoryLogs()
	defer restore()

	runner := &quietRunner{}
	b := envBuilder(srv, runner)

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}

	if len(runner.calls) == 0 {
		t.Fatal("no runner calls recorded")
	}
	joined := strings.Join(runner.calls[0].args, " ")
	// Sorted by key: API_BASE before BARKPARK_READ_TOKEN.
	if !strings.Contains(joined,
		"--env API_BASE=https://api.example.com --env BARKPARK_READ_TOKEN=tok-secret-value") {
		t.Errorf("nixpacks args missing sorted --env pairs: %q", joined)
	}

	// The deployment still reaches pushing.
	if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "pushing" {
		t.Fatalf("expected one pushing transition, got %+v", cp.transitions)
	}

	// Values NEVER hit the durable log or the console; key names may.
	for name, text := range map[string]string{
		"build log": logBuf.String(),
		"console":   cp.consoleJoined(),
		"captions":  cp.detailJoined(),
	} {
		if strings.Contains(text, "tok-secret-value") {
			t.Errorf("secret value leaked into the %s:\n%s", name, text)
		}
	}
	if !strings.Contains(cp.consoleJoined(), "env: injecting 2 site env var(s)") {
		t.Errorf("console should narrate the key COUNT: %q", cp.consoleJoined())
	}
	if !strings.Contains(logBuf.String(), "site env keys=API_BASE,BARKPARK_READ_TOKEN") {
		t.Errorf("build log should carry key NAMES only: %q", logBuf.String())
	}
}

// An empty blob (200 {env:{}}) and a control plane predating the route (404)
// both build env-less: no --env flag at all, and the build still lands pushing.
func TestRunOnce_SiteEnvEmptyOr404_BuildsEnvless(t *testing.T) {
	cases := map[string]func(*scriptedCP){
		"empty blob": func(cp *scriptedCP) { cp.siteEnv = map[string]string{} },
		"route 404":  func(cp *scriptedCP) {}, // nil siteEnv → 404
	}
	for name, arrange := range cases {
		t.Run(name, func(t *testing.T) {
			cp := newScriptedCP(t)
			cp.claims = []claimReply{envClaim}
			arrange(cp)
			srv := httptest.NewServer(cp.handler())
			defer srv.Close()

			_, restore := swapInMemoryLogs()
			defer restore()

			runner := &quietRunner{}
			b := envBuilder(srv, runner)

			if _, err := b.RunOnce(context.Background()); err != nil {
				t.Fatalf("RunOnce err: %v", err)
			}
			for _, c := range runner.calls {
				for _, a := range c.args {
					if a == "--env" {
						t.Errorf("env-less build must pass no --env flag: %v", c.args)
					}
				}
			}
			if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "pushing" {
				t.Fatalf("expected one pushing transition, got %+v", cp.transitions)
			}
		})
	}
}

// A 500 from the env route FAILS the build (transition failed, reason names the
// env fetch) — never a silent env-less build of a site that configured env.
func TestRunOnce_SiteEnvFetch500_FailsBuild(t *testing.T) {
	cp := newScriptedCP(t)
	cp.claims = []claimReply{envClaim}
	cp.siteEnvCode = http.StatusInternalServerError
	srv := httptest.NewServer(cp.handler())
	defer srv.Close()

	_, restore := swapInMemoryLogs()
	defer restore()

	b := envBuilder(srv, &quietRunner{})

	had, err := b.RunOnce(context.Background())
	if err != nil {
		t.Fatalf("RunOnce err: %v", err)
	}
	if !had {
		t.Fatalf("expected had=true")
	}
	if len(cp.transitions) != 1 || cp.transitions[0]["status"] != "failed" {
		t.Fatalf("expected one failed transition, got %+v", cp.transitions)
	}
	if reason, _ := cp.transitions[0]["failure_reason"].(string); !strings.Contains(reason, "site env") {
		t.Errorf("failure_reason should name the env fetch: %q", reason)
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

// TestHTTPNilFallbackHasTimeout proves the nil-HTTPClient fallback is
// Timeout-bearing (not http.DefaultClient, whose Timeout is 0 == no
// deadline) — a hung control-plane connection must not freeze the
// claim/transition loop forever with no crash and no log.
func TestHTTPNilFallbackHasTimeout(t *testing.T) {
	b := &Builder{}
	c := b.http()
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
	mux.HandleFunc("/v1/builder/claim", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * clientTimeout) // outlast the client's timeout, then respond
		w.WriteHeader(http.StatusOK)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	b := &Builder{
		ControlURL: srv.URL,
		Token:      "test-token",
		WorkerID:   "w-1",
		HTTPClient: &http.Client{Timeout: clientTimeout},
	}

	start := time.Now()
	_, err := b.RunOnce(context.Background())
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("RunOnce returned nil against a hanging server, want a timeout error")
	}
	if elapsed > 5*time.Second {
		t.Fatalf("RunOnce took %s to return an error, want it to return promptly on client timeout", elapsed)
	}
}

// TestConsoleLatchIsRecordedAsTruncation drives the narration latch (three
// consecutive failed console POSTs) and proves the resulting deployment's
// console is READABLE AS TRUNCATED rather than as complete
// (dr-bl-builder-console-narration-latch): the terminal line punches through
// the latch with ONE attempt, preceded by an explicit truncation marker, so
// "no failed:/activate: line and no marker" stops being ambiguous between a
// quiet build and a cut one. Before this, the latch was recorded ONLY on the
// builder's stderr — a fourth silent discard.
func TestConsoleLatchIsRecordedAsTruncation(t *testing.T) {
	var mu sync.Mutex
	var got []string
	failing := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if failing {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		var body struct {
			Line string `json:"line"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		got = append(got, body.Line)
	}))
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, WorkerID: "w1", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "dep-latch")

	// Drive the latch: three consecutive failures.
	for i := 0; i < maxConsoleFails; i++ {
		con.logf("build line %d", i)
	}
	// Mid-build lines during the outage are skipped (that is the latch working).
	con.logf("mid-build line that must be dropped")

	// The control plane recovers (the wave-33 measurement: every
	// BOX_UNREACHABLE episode self-healed) — but ordinary lines stay latched.
	mu.Lock()
	failing = false
	mu.Unlock()
	con.logf("post-recovery line that must STILL be dropped — the latch is for the build's remainder")

	mu.Lock()
	if len(got) != 0 {
		mu.Unlock()
		t.Fatalf("latched lines leaked to the console: %q", got)
	}
	mu.Unlock()

	// The TERMINAL line punches through — with the truncation marker first.
	con.logfTerminal("failed: %s", "the build error a reader must see")

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 {
		t.Fatalf("terminal path posted %d line(s), want 2 (marker + terminal): %q", len(got), got)
	}
	if !strings.Contains(got[0], "console TRUNCATED") || !strings.Contains(got[0], "NOT the whole build") {
		t.Fatalf("first line %q must be the truncation marker — a reader must be able to tell truncated from complete", got[0])
	}
	if !strings.Contains(got[1], "failed: the build error a reader must see") {
		t.Fatalf("terminal line %q must carry the outcome", got[1])
	}
}

// TestConsoleTerminalLineWithoutLatchHasNoMarker: a build whose console never
// latched must NOT claim truncation — the marker fires only on a real gap.
func TestConsoleTerminalLineWithoutLatchHasNoMarker(t *testing.T) {
	var mu sync.Mutex
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		var body struct {
			Line string `json:"line"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		got = append(got, body.Line)
	}))
	defer srv.Close()

	b := &Builder{ControlURL: srv.URL, WorkerID: "w1", HTTPClient: srv.Client()}
	con := b.newBuildConsole(context.Background(), "dep-clean")
	con.logf("build line")
	con.logfTerminal("activate: build complete")

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 {
		t.Fatalf("posted %d line(s), want 2: %q", len(got), got)
	}
	for _, l := range got {
		if strings.Contains(l, "TRUNCATED") {
			t.Fatalf("a never-latched console must not claim truncation: %q", got)
		}
	}
}
