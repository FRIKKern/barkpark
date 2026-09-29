package cli

// cloud_site_dataset_refusal_test.go proves ONE claim about `bp cloud site
// create`: when --dataset does not resolve, the refusal NAMES the verb that
// enumerates the triples the caller may type — `bp cloud workspace ls` — the way
// the missing-`--instance` refusal names `bp cloud status` (siteInstanceRequired).
//
// Why a separate file: the three refusals are shape checks inside
// parseDatasetTriple, and they fire BEFORE any control-plane call. A test that
// only asserted the string could therefore pass against a command that never
// reaches the network at all — so every arm here runs against a REAL fake
// control plane (httptest, the /v1 route shapes cloudclient speaks) and asserts
// the plane was never touched, with a control arm that DOES reach it. Without
// that control, "the plane saw 0 requests" is not evidence of an early refusal;
// it is equally consistent with a fixture that could never have been reached.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// fakeControlPlane is a working POST /v1/sites + GET /v1/barkparks control plane:
// `box-1` resolves to `bp-1`, and a create returns a plausible spawner envelope.
// It counts every request it sees so a caller can assert the plane was (or was
// not) reached. It is deliberately a SUCCESS fixture — a refusal proven against a
// plane that would have said yes is a refusal the CLI owns.
func fakeControlPlane(t *testing.T) (url string, hits func() []string) {
	t.Helper()
	var mu sync.Mutex
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		seen = append(seen, r.Method+" "+r.URL.Path)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "GET" && r.URL.Path == "/v1/barkparks":
			_, _ = w.Write([]byte(`{"barkparks":[{"id":"bp-1","name":"box-1","slug":"box-1","health_status":"healthy"}]}`))
		case r.Method == "POST" && r.URL.Path == "/v1/sites":
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"site":{"id":"site-9","barkpark_id":"bp-1","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"web","dataset":"production","url":"https://blog.example.com"},"content_binding":{"status":"ok"}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found"}}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), seen...)
	}
}

// loginAgainst points the on-disk config at the fake control plane and clears the
// env tier, so the verb authenticates the way a logged-in operator does and the
// developer's own BARKPARK_CLOUD_TOKEN can never leak into the run.
func loginAgainst(t *testing.T, cpURL string) {
	t.Helper()
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	t.Setenv(CloudTokenEnv, "")
	t.Chdir(t.TempDir())
	if err := SaveConfig(&Config{
		Server:     cpURL,
		Token:      "content-tok",
		CloudURL:   cpURL,
		CloudToken: "cloud-tok",
	}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// runSiteCreate drives the FULL runCloud dispatcher (not runCloudSiteCreate), so
// the noun/verb wiring is part of what is proved.
func runSiteCreate(t *testing.T, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	code := runCloud(w, globals{}, append([]string{"site", "create"}, args...))
	return sout.String(), serr.String(), code
}

// TestCloudSiteCreateUnresolvableDatasetNamesWorkspaceLister is the DETECTOR, one
// arm per --dataset refusal parseDatasetTriple can emit: missing, wrong arity,
// and an empty segment. Each must (a) exit usage, (b) name `bp cloud workspace
// ls`, and (c) never touch the control plane.
func TestCloudSiteCreateUnresolvableDatasetNamesWorkspaceLister(t *testing.T) {
	cases := []struct {
		name  string
		flags []string
		arm   string // the refusal sentence this arm is supposed to hit
	}{
		{"missing", []string{"--name", "blog", "--instance", "box-1"}, "--dataset is required"},
		{"two-parts", []string{"--name", "blog", "--instance", "box-1", "--dataset", "acme/web"}, "three slash-separated parts"},
		{"empty-part", []string{"--name", "blog", "--instance", "box-1", "--dataset", "acme//production"}, "must have no empty part"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cpURL, hits := fakeControlPlane(t)
			loginAgainst(t, cpURL)

			stdout, stderr, code := runSiteCreate(t, tc.flags...)
			all := stdout + stderr
			if code != exitUsage {
				t.Fatalf("exit = %d, want %d (usage refusal)\nstdout:%s\nstderr:%s", code, exitUsage, stdout, stderr)
			}
			if !strings.Contains(all, tc.arm) {
				t.Fatalf("this case did not reach the %q arm — the table no longer exercises what it names; output:\n%s", tc.arm, all)
			}
			if !strings.Contains(all, "bp cloud workspace ls") {
				t.Fatalf("the %s --dataset refusal does not name the lister verb.\n"+
					"`--instance` names `bp cloud status` in the same command (siteInstanceRequired); a --dataset\n"+
					"refusal that only says the input is wrong leaves the caller to GUESS a triple.\noutput:\n%s",
					tc.name, all)
			}
			if got := hits(); len(got) != 0 {
				t.Fatalf("the refusal must precede every control-plane call; the plane saw %v", got)
			}
		})
	}
}

// TestCloudSiteCreateFakeControlPlaneIsReachable is the CONTROL for the
// zero-requests assertion above. With a WELL-FORMED triple the very same fixture
// is reached and the create succeeds — so "the plane saw 0 requests" in the
// detector is a fact about the refusal, not about an unreachable fixture.
func TestCloudSiteCreateFakeControlPlaneIsReachable(t *testing.T) {
	cpURL, hits := fakeControlPlane(t)
	loginAgainst(t, cpURL)

	stdout, stderr, code := runSiteCreate(t,
		"--name", "blog", "--instance", "box-1", "--dataset", "acme/web/production")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 with a resolvable triple\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	got := hits()
	var sawCreate bool
	for _, h := range got {
		if h == "POST /v1/sites" {
			sawCreate = true
		}
	}
	if !sawCreate {
		t.Fatalf("the control arm never reached POST /v1/sites; the plane saw %v — the detector's\n"+
			"zero-requests assertion would then prove nothing", got)
	}
	if strings.Contains(stdout+stderr, "bp cloud workspace ls") {
		t.Fatalf("a SUCCESSFUL create must not carry the refusal hint; output:\n%s%s", stdout, stderr)
	}
}

// TestCloudSiteCreateDatasetHintNamesADispatchableVerb closes the rot gap the
// string assertion leaves open: a refusal may name a verb that does not exist.
// The verb is READ OUT of siteDatasetListHint (not retyped here) and dispatched
// through runCloud — if someone renames or deletes `bp cloud workspace ls`, this
// reds even though the hint text still "looks right".
func TestCloudSiteCreateDatasetHintNamesADispatchableVerb(t *testing.T) {
	verb := backtickedCommand(t, siteDatasetListHint)
	parts := strings.Fields(verb)
	if len(parts) < 3 || parts[0] != "bp" || parts[1] != "cloud" {
		t.Fatalf("hint names %q; expected a `bp cloud <noun> <verb>` command", verb)
	}

	// A content-API fake: the lister walks the membership-scoped switcher reads.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/datasets"):
			_, _ = w.Write([]byte(`{"datasets":[{"id":"d1","slug":"production","name":"production"}]}`))
		case strings.HasSuffix(r.URL.Path, "/projects"):
			_, _ = w.Write([]byte(`{"projects":[{"id":"p1","slug":"web","name":"web"}]}`))
		default:
			_, _ = w.Write([]byte(`{"workspaces":[{"id":"w1","slug":"acme","name":"acme"}]}`))
		}
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	clearBarkparkEnv(t)

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "json"
	w.color = false
	// runCloud IS the `cloud` noun, so it takes everything after it.
	code := runCloud(w, globals{server: srv.URL, token: "tok"}, parts[2:])
	all := sout.String() + serr.String()
	if strings.Contains(all, "unknown workspace command") || strings.Contains(all, "unknown cloud command") {
		t.Fatalf("the --dataset refusal names %q, which `bp` does not dispatch:\n%s", verb, all)
	}
	if code != exitOK {
		t.Fatalf("%q exited %d against a working content API:\n%s", verb, code, all)
	}
	// The verb must actually produce the pasteable triple the hint promises.
	var env struct {
		Datasets []string `json:"datasets"`
	}
	if err := json.Unmarshal([]byte(sout.String()), &env); err != nil {
		t.Fatalf("decode %q -o json: %v\n%s", verb, err, sout.String())
	}
	if len(env.Datasets) == 0 || !strings.Contains(env.Datasets[0], "/") {
		t.Fatalf("%q must print a pasteable ws/proj/ds triple; got %v", verb, env.Datasets)
	}
}

// backtickedCommand pulls the first `…`-quoted command out of a hint string, so
// the test dispatches the verb the CODE names rather than one the test author
// remembered.
func backtickedCommand(t *testing.T, s string) string {
	t.Helper()
	i := strings.Index(s, "`")
	if i < 0 {
		t.Fatalf("hint names no backticked command: %q", s)
	}
	rest := s[i+1:]
	j := strings.Index(rest, "`")
	if j < 0 {
		t.Fatalf("hint has an unclosed backtick: %q", s)
	}
	return strings.TrimSpace(rest[:j])
}
