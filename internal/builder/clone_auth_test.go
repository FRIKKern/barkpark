package builder

import (
	"encoding/base64"
	"net/http"
	"net/http/cgi"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// --- a REAL private git remote, hermetic -------------------------------------
//
// The clone lane's private-repo behavior cannot be honestly proven against a
// `file://` fixture (the filesystem never asks who you are) and must not be
// proven against live GitHub (network + a real private repo neither CI nor a
// worktree agent has). So: serve the SAME bare fixture repo over real HTTP via
// `git http-backend`, behind real HTTP Basic auth. Anonymous fetches get a 401
// + WWW-Authenticate exactly as github.com answers for a private repo; an
// authenticated one gets the real smart-http protocol.
//
// gitHTTPFixture reports the served URL and the credentials the server demands.
type gitHTTPFixture struct {
	URL       string
	TipSHA    string
	ParentSHA string
	User      string
	Token     string

	// authorizations records the Authorization header of every request the
	// server saw (empty string for an anonymous one) — so a test can assert
	// HOW git authenticated, not merely that the fetch exited 0.
	authorizations []string
}

func makeAuthedRepoFixture(t *testing.T) *gitHTTPFixture {
	t.Helper()

	fileURL, tip, parent := makeBareRepoFixture(t)
	bare := strings.TrimPrefix(fileURL, "file://")
	root := filepath.Dir(bare)

	gitBin, err := exec.LookPath("git")
	if err != nil {
		t.Skipf("git not on PATH: %v", err)
	}

	fx := &gitHTTPFixture{
		TipSHA:    tip,
		ParentSHA: parent,
		User:      "x-access-token",
		Token:     "ghs_fixture_installation_token",
	}

	backend := &cgi.Handler{
		Path: gitBin,
		Args: []string{"http-backend"},
		Env: []string{
			"GIT_PROJECT_ROOT=" + root,
			"GIT_HTTP_EXPORT_ALL=1",
		},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fx.authorizations = append(fx.authorizations, r.Header.Get("Authorization"))

		u, p, ok := r.BasicAuth()
		if !ok || u != fx.User || p != fx.Token {
			w.Header().Set("WWW-Authenticate", `Basic realm="barkpark-fixture"`)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		backend.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	fx.URL = srv.URL + "/" + filepath.Base(bare)
	return fx
}

// sanity: the fixture really is a working git remote once you authenticate —
// otherwise a "clone failed" result below would prove nothing about auth.
func TestAuthedRepoFixture_IsARealRemoteWhenAuthenticated(t *testing.T) {
	fx := makeAuthedRepoFixture(t)

	dir := t.TempDir()
	run := func(args ...string) (string, error) {
		cmd := gitCommand(t.Context(), dir, args...)
		out, err := cmd.CombinedOutput()
		return string(out), err
	}
	if out, err := run("init", "--quiet"); err != nil {
		t.Fatalf("init: %v %s", err, out)
	}
	authURL := strings.Replace(fx.URL, "http://", "http://"+fx.User+":"+fx.Token+"@", 1)
	if out, err := run("remote", "add", "origin", authURL); err != nil {
		t.Fatalf("remote add: %v %s", err, out)
	}
	if out, err := run("fetch", "--depth", "1", "origin", fx.ParentSHA); err != nil {
		t.Fatalf("authenticated fetch of a non-tip sha should succeed: %v\n%s", err, out)
	}
}

// THE REPRODUCTION. A webhook-created deployment on a PRIVATE connected repo:
// the control plane hands the builder a source envelope with no credential in
// it, so cloneGitSource fetches anonymously and the build can never start.
func TestCloneGitSource_PrivateRepo_NoToken_FailsTerminally(t *testing.T) {
	fx := makeAuthedRepoFixture(t)
	b := &Builder{}

	_, err := b.cloneGitSource(t.Context(), &BuildSource{
		Kind: "git",
		URL:  fx.URL,
		Ref:  fx.ParentSHA,
	})
	if err == nil {
		t.Fatalf("expected the anonymous clone of a private repo to fail")
	}
	t.Logf("REPRO — anonymous clone of a private repo: %v", err)
	if !strings.Contains(err.Error(), "terminal:") {
		t.Fatalf("want a terminal classification, got: %v", err)
	}
	// The reason must send the operator to the thing that actually fixes it:
	// connecting GitHub. Before this change it said "authenticated GitHub
	// access is not yet supported", which is now false.
	if !strings.Contains(err.Error(), "connect GitHub") {
		t.Fatalf("want a reason pointing at the GitHub connection, got: %v", err)
	}
}

// THE FIX. The same private repo, the same sha, plus the installation token the
// control plane now mints into the claim envelope: the clone SUCCEEDS and the
// checkout is exactly the requested commit.
func TestCloneGitSource_PrivateRepo_WithToken_ClonesAtExactSHA(t *testing.T) {
	fx := makeAuthedRepoFixture(t)
	b := &Builder{}

	// Deliberately the PARENT sha, not the branch tip: it is reachable but not
	// advertised, so this can only pass by fetching the exact object — a
	// moving branch head would land on TipSHA instead.
	dir, err := b.cloneGitSource(t.Context(), &BuildSource{
		Kind:  "git",
		URL:   fx.URL,
		Ref:   fx.ParentSHA,
		Token: fx.Token,
	})
	if err != nil {
		t.Fatalf("authenticated clone should succeed: %v", err)
	}

	head := gitOut(t, dir, "rev-parse", "HEAD")
	if head != fx.ParentSHA {
		t.Fatalf("checked out %s, want the exact webhook sha %s (tip is %s)", head, fx.ParentSHA, fx.TipSHA)
	}

	// STATE, not exit code: the working tree is the parent commit's content.
	body, err := os.ReadFile(filepath.Join(dir, "marker.txt"))
	if err != nil {
		t.Fatalf("read checkout: %v", err)
	}
	if strings.TrimSpace(string(body)) != "v1" {
		t.Fatalf("checkout content = %q, want the parent commit's %q", body, "v1")
	}

	// And it authenticated the way we intended — a Basic header, never a
	// credential in the URL.
	if !sawBasicAuth(fx, fx.Token) {
		t.Fatalf("server never saw the installation token as Basic auth; headers: %v", fx.authorizations)
	}
}

// The credential must never be reachable from the clone workdir: nothing
// writes it into the remote URL, so a later `git remote` read (or anything
// that reads the repo config) cannot recover it.
func TestCloneGitSource_TokenNeverPersistedInTheWorkdir(t *testing.T) {
	fx := makeAuthedRepoFixture(t)
	b := &Builder{}

	dir, err := b.cloneGitSource(t.Context(), &BuildSource{
		Kind: "git", URL: fx.URL, Ref: fx.ParentSHA, Token: fx.Token,
	})
	if err != nil {
		t.Fatalf("clone: %v", err)
	}

	cfg, err := os.ReadFile(filepath.Join(dir, ".git", "config"))
	if err != nil {
		t.Fatalf("read repo config: %v", err)
	}
	if strings.Contains(string(cfg), fx.Token) {
		t.Fatalf("the installation token was persisted into the clone's git config:\n%s", cfg)
	}
	if got := gitOut(t, dir, "remote", "get-url", "origin"); strings.Contains(got, fx.Token) {
		t.Fatalf("origin url carries the credential: %s", got)
	}
}

// A token the installation does not cover (repo not granted, token expired):
// the server refuses, and the failure names the GRANT, not the connection.
func TestCloneGitSource_TokenRefused_NamesTheGrant(t *testing.T) {
	fx := makeAuthedRepoFixture(t)
	b := &Builder{}

	_, err := b.cloneGitSource(t.Context(), &BuildSource{
		Kind: "git", URL: fx.URL, Ref: fx.ParentSHA, Token: "ghs_wrong_token",
	})
	if err == nil {
		t.Fatalf("a refused token must fail the clone")
	}
	if !strings.Contains(err.Error(), "terminal:") || !strings.Contains(err.Error(), "grant") {
		t.Fatalf("want a terminal grant-scoped reason, got: %v", err)
	}
	if strings.Contains(err.Error(), "ghs_wrong_token") {
		t.Fatalf("the failure reason leaks the credential: %v", err)
	}
}

// gitAuthEnv is the whole security surface of the credential. Pin it.
func TestGitAuthEnv(t *testing.T) {
	t.Run("no token → no auth env", func(t *testing.T) {
		env, err := gitAuthEnv(&BuildSource{URL: "https://github.com/o/r.git", Ref: "abc"})
		if err != nil || env != nil {
			t.Fatalf("got (%v, %v), want (nil, nil)", env, err)
		}
	})

	t.Run("https → an origin-scoped extraHeader on the ENVIRONMENT", func(t *testing.T) {
		env, err := gitAuthEnv(&BuildSource{URL: "https://github.com/o/r.git", Token: "tok"})
		if err != nil {
			t.Fatal(err)
		}
		joined := strings.Join(env, "\n")
		// Scoped to github.com — a bare `http.extraHeader` would hand the token
		// to whatever host a redirect pointed at.
		if !strings.Contains(joined, "GIT_CONFIG_KEY_0=http.https://github.com/.extraHeader") {
			t.Fatalf("auth env is not origin-scoped:\n%s", joined)
		}
		want := "Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:tok"))
		if !strings.Contains(joined, want) {
			t.Fatalf("auth env missing the Basic header:\n%s", joined)
		}
	})

	t.Run("cleartext http to a remote host is REFUSED", func(t *testing.T) {
		_, err := gitAuthEnv(&BuildSource{URL: "http://evil.example.com/o/r.git", Token: "tok"})
		if err == nil {
			t.Fatalf("sending a credential over cleartext http must be refused")
		}
		if strings.Contains(err.Error(), "tok") {
			t.Fatalf("refusal leaks the credential: %v", err)
		}
	})

	t.Run("unparseable url is REFUSED", func(t *testing.T) {
		if _, err := gitAuthEnv(&BuildSource{URL: "://nope", Token: "tok"}); err == nil {
			t.Fatalf("an unparseable url must not receive a credential")
		}
	})
}

// A ref is an ARGUMENT to git, and `git_ref` is caller-supplied on the manual
// deploy route (POST /v1/sites/:id/deploy) with no format constraint in the
// changeset.
//
// The harm here was MEASURED, not assumed. Removing both guards and running
// this input produced: err=<nil>, and HEAD == the branch TIP — git's option
// parser swallowed the ref, the fetch fell through to the default refspec, and
// the builder shipped a commit nobody asked for while reporting success. (No
// command ran: `--upload-pack` is inert over https. The defect is the silent
// wrong build, which is the same moving-branch-head failure this lane exists
// to prevent.)
func TestCloneGitSource_RefusesOptionLookingRef(t *testing.T) {
	fx := makeAuthedRepoFixture(t)
	b := &Builder{}

	dir, err := b.cloneGitSource(t.Context(), &BuildSource{
		Kind:  "git",
		URL:   fx.URL,
		Ref:   "--upload-pack=/bin/true",
		Token: fx.Token,
	})
	if err == nil {
		t.Fatalf("an option-shaped ref must be refused; instead the clone succeeded at HEAD=%s (tip=%s)",
			gitOut(t, dir, "rev-parse", "HEAD"), fx.TipSHA)
	}
	if !strings.Contains(err.Error(), "may not start with") {
		t.Fatalf("want the option-shaped-ref refusal, got: %v", err)
	}
	if dir != "" {
		t.Fatalf("a refused ref must not leave a workdir behind: %q", dir)
	}
}

// --- helpers -----------------------------------------------------------------

func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := gitCommand(t.Context(), dir, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func sawBasicAuth(fx *gitHTTPFixture, token string) bool {
	want := "Basic " + base64.StdEncoding.EncodeToString([]byte(fx.User+":"+token))
	for _, got := range fx.authorizations {
		if got == want {
			return true
		}
	}
	return false
}
