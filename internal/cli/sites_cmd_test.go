package cli

// sites_cmd_test.go drives the P6 `bp sites` / `bp deploy` surface against a
// scripted httptest server — the same idiom cloud12_cmd_test.go uses for the
// cloud-12 commands. Each test seeds a Cloud token via seedCloudLogin, points
// the saved CloudURL at the fake server, then exercises one sub-command and
// asserts (a) the wire path/body, (b) the renderered output, and (c) the exit
// code. No live network — every request hits the local server.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

// scriptedCloud is a small router that maps METHOD+PATH (and optionally a
// path-prefix) to a canned response, so one fake server can answer the full
// matrix of /v1/barkparks /v1/sites /v1/sites/:id /v1/sites/:id/* a sites test
// needs. Unknown paths 404 — the harness logs every request so a missing key is
// obvious in test output.
type scriptedCloud struct {
	t        *testing.T
	routes   map[string]scriptedRoute
	requests []scriptedRequest
}

type scriptedRoute struct {
	status int
	body   string
}

type scriptedRequest struct {
	method string
	path   string
	auth   string
	body   map[string]any
}

func newScriptedCloud(t *testing.T) *scriptedCloud {
	return &scriptedCloud{t: t, routes: map[string]scriptedRoute{}}
}

func (s *scriptedCloud) route(method, path string, status int, body string) *scriptedCloud {
	s.routes[method+" "+path] = scriptedRoute{status, body}
	return s
}

func (s *scriptedCloud) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := scriptedRequest{method: r.Method, path: r.URL.Path, auth: r.Header.Get("Authorization")}
		if r.Body != nil {
			raw, _ := io.ReadAll(r.Body)
			if len(raw) > 0 {
				_ = json.Unmarshal(raw, &rec.body)
			}
		}
		s.requests = append(s.requests, rec)
		if route, ok := s.routes[r.Method+" "+r.URL.Path]; ok {
			w.WriteHeader(route.status)
			_, _ = io.WriteString(w, route.body)
			return
		}
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":"not_found"}`)
	})
}

// requestsFor returns every recorded request that matched method+path.
func (s *scriptedCloud) requestsFor(method, path string) []scriptedRequest {
	var out []scriptedRequest
	for _, r := range s.requests {
		if r.method == method && r.path == path {
			out = append(out, r)
		}
	}
	return out
}

// TestSitesListRendersTable: `bp sites` with two sites + one returning
// deployments. The table carries NAME, DOMAINS, STATUS, LAST DEPLOY.
func TestSitesListRendersTable(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"dep-a","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z"},
			{"id":"site-2","barkpark_id":"bp-1","team_id":"team-1","name":"Shop","slug":"shop","framework":"nextjs","domains":[],"scale_mode":"zero","port":0,"current_deployment_id":"","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-a","site_id":"site-1","status":"live","image_tag":"sha:b","inserted_at":"2026-06-26T02:00:00Z"}
		]}`).
		route("GET", "/v1/sites/site-2/deployments", http.StatusOK, `{"deployments":[]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	// Header columns appear.
	for _, want := range []string{"NAME", "DOMAINS", "STATUS", "LAST DEPLOY"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing column %q:\n%s", want, stdout)
		}
	}
	// Both sites + the live status of site-1.
	for _, want := range []string{"Blog", "Shop", "blog.example.com", "live"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing %q:\n%s", want, stdout)
		}
	}
	// The /v1/sites GET carried the Bearer.
	reqs := s.requestsFor("GET", "/v1/sites")
	if len(reqs) == 0 || reqs[0].auth != "Bearer sess-abc" {
		t.Fatalf("expected bearer auth on /v1/sites; requests = %+v", s.requests)
	}
}

// TestSitesListEmptyRendersHint: zero sites prints the "create one" hint, not
// an empty table.
func TestSitesListEmptyRendersHint(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, `{"sites":[]}`)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "no sites yet") {
		t.Fatalf("expected the empty-sites hint:\n%s", stdout)
	}
}

// TestSitesCreateResolvesBarkparkSlug: `bp sites create --barkpark blog --name Blog`
// resolves the slug "blog" to a UUID via /v1/barkparks, then POSTs /v1/sites
// with that UUID + name. Asserts the right body landed.
func TestSitesCreateResolvesBarkparkSlug(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/barkparks", http.StatusOK, `{"barkparks":[
			{"id":"bp-uuid-1","name":"prod","slug":"prod","mode":"managed"},
			{"id":"bp-uuid-2","name":"blog","slug":"blog","mode":"managed"}
		]}`).
		route("POST", "/v1/sites", http.StatusCreated, `{"site":{"id":"site-7","barkpark_id":"bp-uuid-2","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"create",
			"--barkpark", "blog", "--name", "Blog",
			"--framework", "nextjs",
			"--domain", "blog.example.com",
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "created site") {
		t.Fatalf("expected creation confirmation:\n%s", stdout)
	}
	reqs := s.requestsFor("POST", "/v1/sites")
	if len(reqs) != 1 {
		t.Fatalf("expected one POST /v1/sites, got %d", len(reqs))
	}
	body := reqs[0].body
	if body["barkpark_id"] != "bp-uuid-2" {
		t.Fatalf("barkpark slug must have resolved to bp-uuid-2; body = %v", body)
	}
	if body["name"] != "Blog" || body["framework"] != "nextjs" {
		t.Fatalf("site body wrong: %v", body)
	}
	doms, ok := body["domains"].([]any)
	if !ok || len(doms) != 1 || doms[0] != "blog.example.com" {
		t.Fatalf("domains body wrong: %v", body["domains"])
	}
}

// TestSitesCreateRequiresFlags: missing --barkpark or --name is a usage error
// and never hits the wire.
func TestSitesCreateRequiresFlags(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"create", "--name", "Blog"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("--barkpark")) {
		t.Fatalf("expected --barkpark requirement in stderr:\n%s", stderr)
	}
	if len(s.requests) != 0 {
		t.Fatalf("a usage error must not hit the wire; got %d requests", len(s.requests))
	}
}

// TestDeployPostsCorrectBody: `bp deploy blog --artifact-url file:///tmp/x.tar`
// resolves the slug "blog" via /v1/sites, then POSTs /v1/sites/<id>/deploy
// with the artifact_url. The queued deployment renders.
func TestDeployPostsCorrectBody(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/deploy", http.StatusCreated, `{"deployment":{"id":"dep-1","site_id":"site-1","status":"queued","git_ref":"","artifact_url":"file:///tmp/x.tar"}}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDeploy(out, []string{"blog", "--artifact-url", "file:///tmp/x.tar"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "queued deployment dep-1") {
		t.Fatalf("expected confirmation of queued deploy:\n%s", stdout)
	}
	reqs := s.requestsFor("POST", "/v1/sites/site-1/deploy")
	if len(reqs) != 1 {
		t.Fatalf("expected one deploy POST, got %d", len(reqs))
	}
	if reqs[0].body["artifact_url"] != "file:///tmp/x.tar" {
		t.Fatalf("deploy body wrong: %v", reqs[0].body)
	}
}

// TestDeployTarballsCwdByDefault: with neither --artifact-url nor --git-ref
// the command tarballs the project dir (here a tmpdir with one tiny file),
// streams it to /v1/sites/:id/artifact, then POSTs /v1/sites/:id/deploy with
// the returned `file://` URL. This is the P7 "heroku moment".
func TestDeployTarballsCwdByDefault(t *testing.T) {
	withTempConfigHome(t)

	tmp := t.TempDir()
	if err := writeFile(tmp+"/index.js", []byte("console.log('hi')\n")); err != nil {
		t.Fatal(err)
	}

	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/artifact", http.StatusCreated, `{"artifact_url":"file:///tmp/blog-abc.tar.gz","bytes":1234,"filename":"blog-abc.tar.gz"}`).
		route("POST", "/v1/sites/site-1/deploy", http.StatusCreated, `{"deployment":{"id":"dep-9","site_id":"site-1","status":"queued","artifact_url":"file:///tmp/blog-abc.tar.gz"}}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDeploy(out, []string{"blog", "--dir", tmp})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}

	// The artifact upload landed first.
	upReqs := s.requestsFor("POST", "/v1/sites/site-1/artifact")
	if len(upReqs) != 1 {
		t.Fatalf("expected one artifact POST, got %d", len(upReqs))
	}
	// Then the deploy was queued with the returned URL.
	depReqs := s.requestsFor("POST", "/v1/sites/site-1/deploy")
	if len(depReqs) != 1 {
		t.Fatalf("expected one deploy POST, got %d", len(depReqs))
	}
	if depReqs[0].body["artifact_url"] != "file:///tmp/blog-abc.tar.gz" {
		t.Fatalf("deploy did not echo uploaded URL: %v", depReqs[0].body)
	}
	if !strings.Contains(stdout, "queued deployment dep-9") {
		t.Fatalf("expected queued-deployment confirmation:\n%s", stdout)
	}
}

// TestDeployArtifactURLEscapeHatch: `bp deploy <site> --artifact-url …`
// still works, skipping the tarball upload — the documented escape hatch.
// Mirror of the original TestDeployRequiresArtifactOrRef's contract that
// --artifact-url is honored verbatim.
func TestDeployArtifactURLEscapeHatch(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/deploy", http.StatusCreated, `{"deployment":{"id":"dep-2","site_id":"site-1","status":"queued","artifact_url":"file:///pre/built.tar.gz"}}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDeploy(out, []string{"blog", "--artifact-url", "file:///pre/built.tar.gz"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if len(s.requestsFor("POST", "/v1/sites/site-1/artifact")) != 0 {
		t.Fatal("escape hatch must NOT upload an artifact")
	}
	if len(s.requestsFor("POST", "/v1/sites/site-1/deploy")) != 1 {
		t.Fatal("escape hatch must still enqueue a deploy")
	}
}

// writeFile is a tiny os.WriteFile shim used by the tarball tests so the
// import surface stays exactly the same as before this P7 change.
func writeFile(path string, body []byte) error {
	return os.WriteFile(path, body, 0o644)
}

// TestSitesEnvSetReplacesBlob: `bp sites env set blog FOO=bar BAZ=qux` resolves
// the slug, then POSTs /v1/sites/<id>/env with the env wrapped under "env".
func TestSitesEnvSetReplacesBlob(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/env", http.StatusOK, `{"ok":true}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"env", "set", "blog", "FOO=bar", "BAZ=qux"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "replaced env") {
		t.Fatalf("expected replacement confirmation:\n%s", stdout)
	}
	// Confirm REPLACED warning is surfaced — the env semantics matter to users.
	if !strings.Contains(stdout, "REPLACED") {
		t.Fatalf("env set should warn that it replaced the blob:\n%s", stdout)
	}
	reqs := s.requestsFor("POST", "/v1/sites/site-1/env")
	if len(reqs) != 1 {
		t.Fatalf("expected one env POST, got %d", len(reqs))
	}
	env, ok := reqs[0].body["env"].(map[string]any)
	if !ok {
		t.Fatalf("env body must wrap under \"env\"; got %v", reqs[0].body)
	}
	if env["FOO"] != "bar" || env["BAZ"] != "qux" {
		t.Fatalf("env body wrong: %v", env)
	}
}

// TestSitesEnvSetRejectsBadPair: a positional that lacks "=" is a usage error.
func TestSitesEnvSetRejectsBadPair(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"env", "set", "blog", "BAD-PAIR"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("KEY=VALUE")) {
		t.Fatalf("expected KEY=VALUE hint in stderr:\n%s", stderr)
	}
}

// TestSitesDomainAdd: `bp sites domain add blog www.example.com` resolves the
// slug + POSTs /v1/sites/<id>/domains with {"domain":"..."}.
func TestSitesDomainAdd(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/domains", http.StatusOK, `{"site":{"id":"site-1","slug":"blog","name":"Blog","domains":["blog.example.com","www.example.com"]}}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"domain", "add", "blog", "www.example.com"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "www.example.com") {
		t.Fatalf("expected new domain in output:\n%s", stdout)
	}
	reqs := s.requestsFor("POST", "/v1/sites/site-1/domains")
	if len(reqs) != 1 || reqs[0].body["domain"] != "www.example.com" {
		t.Fatalf("domain POST wrong: %+v", reqs)
	}
}

// TestSitesDeploymentsTable: `bp sites deployments blog` renders STATUS,
// IMAGE_TAG, GIT_REF, STARTED.
func TestSitesDeploymentsTable(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-2","site_id":"site-1","status":"live","image_tag":"sha:bbbb","git_ref":"main","inserted_at":"2026-06-26T02:00:00Z"},
			{"id":"dep-1","site_id":"site-1","status":"failed","image_tag":"","git_ref":"main","failure_reason":"boom","inserted_at":"2026-06-26T01:00:00Z"}
		]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"deployments", "blog"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	for _, want := range []string{"STATUS", "IMAGE_TAG", "GIT_REF", "STARTED", "live", "failed", "sha:bbbb"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("deployments table missing %q:\n%s", want, stdout)
		}
	}
}

// TestSitesLogsPrintsBuildLogURL: best-effort log surface — `bp sites logs blog`
// fetches the most-recent deployment and prints its build_log_url.
func TestSitesLogsPrintsBuildLogURL(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-1","site_id":"site-1","status":"building","build_log_url":"https://logs.example.com/dep-1.log","inserted_at":"2026-06-26T02:00:00Z"}
		]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"logs", "blog"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "https://logs.example.com/dep-1.log") {
		t.Fatalf("expected the build log URL in output:\n%s", stdout)
	}
}

// TestSitesShowRendersDetail: `bp sites show blog` resolves the slug + prints
// the key/value detail block.
func TestSitesShowRendersDetail(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"dep-a"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-a","site_id":"site-1","status":"live","image_tag":"sha:b","git_ref":"main","build_log_url":"https://logs.example.com/dep-a.log","inserted_at":"2026-06-26T02:00:00Z"}
		]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"show", "blog"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	for _, want := range []string{"name:", "Blog", "slug:", "framework:", "nextjs", "last deployment", "live", "sha:b"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("show detail missing %q:\n%s", want, stdout)
		}
	}
}

// TestSitesRequiresLogin: every sites/deploy verb fails exit 3 with no Cloud
// token saved — and never hits the wire.
func TestSitesRequiresLogin(t *testing.T) {
	cases := []struct {
		name string
		run  func(out *writer) int
	}{
		{"sites", func(out *writer) int { return runSites(out, nil) }},
		{"sites create", func(out *writer) int {
			return runSites(out, []string{"create", "--barkpark", "blog", "--name", "Blog"})
		}},
		{"sites deployments", func(out *writer) int { return runSites(out, []string{"deployments", "blog"}) }},
		{"sites env set", func(out *writer) int { return runSites(out, []string{"env", "set", "blog", "K=V"}) }},
		{"sites domain add", func(out *writer) int { return runSites(out, []string{"domain", "add", "blog", "x.example.com"}) }},
		{"sites logs", func(out *writer) int { return runSites(out, []string{"logs", "blog"}) }},
		{"deploy", func(out *writer) int { return runDeploy(out, []string{"blog", "--artifact-url", "file:///tmp/x"}) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t) // fresh empty config — no Cloud token

			_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
				out.output = "table"
				return tc.run(out)
			})
			if code != exitAuth {
				t.Fatalf("%s: exit = %d, want %d (auth)", tc.name, code, exitAuth)
			}
			if !bytes.Contains([]byte(stderr), []byte("bp login")) {
				t.Fatalf("%s: stderr should tell the user to run bp login:\n%s", tc.name, stderr)
			}
		})
	}
}

// TestDoctorIncludesCloudSitesCheck: when a Cloud token is saved, doctor adds
// the cloud-sites probe and the gate reports the site count. The legacy 7-check
// fake server (used by other doctor tests) handles the base probes; we install
// our own scripted cloud for the /v1/sites response.
func TestDoctorIncludesCloudSitesCheck(t *testing.T) {
	withTempConfigHome(t)

	// A Cloud control-plane fake that answers /v1/sites with two registered
	// sites, one live and one with no current_deployment_id (the "no live
	// deployment" signal the gate reports on).
	cloud := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/sites" && r.Method == "GET" {
			_, _ = io.WriteString(w, `{"sites":[
				{"slug":"blog","current_deployment_id":"dep-a"},
				{"slug":"shop","current_deployment_id":""}
			]}`)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer cloud.Close()
	seedCloudLogin(t, cloud.URL)

	// The Barkpark target the doctor probes is a separate fake server that
	// passes every BaseURL check — we only care that the cloud-sites probe is
	// added to the report.
	bp := httptest.NewServer(doctorStatusHandler(http.StatusOK, doctorAllGreen()))
	defer bp.Close()

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDoctor(out, []string{"--url", bp.URL, "--token", "tok"})
	})
	_ = code // we don't require all-green — only that the cloud-sites line appears

	if !strings.Contains(stdout, "cloud-sites") {
		t.Fatalf("expected the cloud-sites check in the doctor report:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 site(s) registered") {
		t.Fatalf("expected the site count in the cloud-sites detail:\n%s", stdout)
	}
	if !strings.Contains(stdout, "shop") {
		t.Fatalf("expected the no-live-deployment site (shop) in the detail:\n%s", stdout)
	}
}

// TestSitesGithubConnectPostsRepoAndBranch drives `bp sites github connect blog
// --repo FRIKKern/barkpark --branch main` against a scripted control plane and
// asserts (a) the slug resolved to a site UUID via /v1/sites, (b) the POST to
// /v1/sites/<id>/github carried the right body shape (repo, branch), and
// (c) the rendered output carries the webhook URL + the plaintext secret the
// server returned (the one-time copy the user pastes into GitHub).
func TestSitesGithubConnectPostsRepoAndBranch(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("POST", "/v1/sites/site-1/github", http.StatusOK, `{
			"site":{"id":"site-1","slug":"blog","name":"Blog","github_repo":"FRIKKern/barkpark","github_branch":"main","github_webhook_configured":true},
			"webhook_url":"https://api.barkpark.cloud/v1/webhooks/github/site-1",
			"webhook_secret":"top-secret-server-generated"
		}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"github", "connect", "blog",
			"--repo", "FRIKKern/barkpark", "--branch", "main",
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	// Confirmation line, webhook URL, and the plaintext secret all surface.
	for _, want := range []string{
		"linked",
		"FRIKKern/barkpark",
		"https://api.barkpark.cloud/v1/webhooks/github/site-1",
		"top-secret-server-generated",
		"Settings → Webhooks",
		"application/json",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("expected %q in github connect output:\n%s", want, stdout)
		}
	}
	// One POST landed with the right body shape.
	reqs := s.requestsFor("POST", "/v1/sites/site-1/github")
	if len(reqs) != 1 {
		t.Fatalf("expected one /github POST, got %d", len(reqs))
	}
	if reqs[0].body["repo"] != "FRIKKern/barkpark" {
		t.Fatalf("repo body wrong: %v", reqs[0].body)
	}
	if reqs[0].body["branch"] != "main" {
		t.Fatalf("branch body wrong: %v", reqs[0].body)
	}
	// The user did NOT supply a secret, so the body must NOT carry one — the
	// server generates it. (omitempty in the client struct ensures this.)
	if _, has := reqs[0].body["webhook_secret"]; has {
		t.Fatalf("body must NOT carry webhook_secret when --secret was omitted; got %v", reqs[0].body)
	}
}

// TestSitesGithubConnectForwardsUserSecret: when --secret is passed, the CLI
// forwards it on the wire so the server stores the user's pre-shared secret
// instead of generating a fresh one.
func TestSitesGithubConnectForwardsUserSecret(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","slug":"blog","name":"Blog"}
		]}`).
		route("POST", "/v1/sites/site-1/github", http.StatusOK, `{
			"site":{"id":"site-1","slug":"blog","name":"Blog","github_repo":"FRIKKern/barkpark","github_branch":"main"},
			"webhook_url":"http://x/v1/webhooks/github/site-1",
			"webhook_secret":"user-supplied-pre-shared"
		}`)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"github", "connect", "blog",
			"--repo", "FRIKKern/barkpark", "--secret", "user-supplied-pre-shared",
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	reqs := s.requestsFor("POST", "/v1/sites/site-1/github")
	if len(reqs) != 1 || reqs[0].body["webhook_secret"] != "user-supplied-pre-shared" {
		t.Fatalf("user --secret must flow on the wire; got body %v", reqs[0].body)
	}
}

// TestSitesGithubConnectRequiresRepo: a connect without --repo is a usage
// error and never hits the wire.
func TestSitesGithubConnectRequiresRepo(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"github", "connect", "blog"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("--repo")) {
		t.Fatalf("expected --repo requirement in stderr:\n%s", stderr)
	}
	if len(s.requests) != 0 {
		t.Fatalf("usage error must not hit the wire; got %d requests", len(s.requests))
	}
}

// TestSitesGithubConnectRequiresSite: a connect without a site handle is a
// usage error.
func TestSitesGithubConnectRequiresSite(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"github", "connect", "--repo", "x/y"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("<site>")) {
		t.Fatalf("expected <site> hint in stderr:\n%s", stderr)
	}
}

// TestSitesGithubConnectRejectsUnknownVerb: only `connect` is supported today;
// any other verb is a usage error.
func TestSitesGithubConnectRejectsUnknownVerb(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"github", "disconnect", "blog"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}
	if !bytes.Contains([]byte(stderr), []byte("connect")) {
		t.Fatalf("expected hint that only 'connect' is supported in stderr:\n%s", stderr)
	}
}

// TestSitesGithubConnectFlagParsing: directly exercises parseGithubConnectArgs
// to confirm the combinations of <site> + --repo + --branch + --secret + the
// `--flag=value` form all parse to the same struct.
func TestSitesGithubConnectFlagParsing(t *testing.T) {
	cases := []struct {
		name                                  string
		args                                  []string
		wantHandle, wantRepo, wantBr, wantSec string
		wantErr                               bool
	}{
		{
			name:       "space-separated values",
			args:       []string{"blog", "--repo", "x/y", "--branch", "dev", "--secret", "s"},
			wantHandle: "blog", wantRepo: "x/y", wantBr: "dev", wantSec: "s",
		},
		{
			name:       "equal-form values",
			args:       []string{"blog", "--repo=x/y", "--branch=dev", "--secret", "s"},
			wantHandle: "blog", wantRepo: "x/y", wantBr: "dev", wantSec: "s",
		},
		{
			name:       "no branch — defaults applied server-side",
			args:       []string{"blog", "--repo", "x/y"},
			wantHandle: "blog", wantRepo: "x/y",
		},
		{
			name:    "unknown flag — error",
			args:    []string{"blog", "--repo", "x/y", "--nope"},
			wantErr: true,
		},
		{
			name:    "two positionals — error",
			args:    []string{"blog", "other", "--repo", "x/y"},
			wantErr: true,
		},
		{
			name:       "--webhook-secret alias",
			args:       []string{"blog", "--repo", "x/y", "--webhook-secret", "abc"},
			wantHandle: "blog", wantRepo: "x/y", wantSec: "abc",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, r, b, s, err := parseGithubConnectArgs(tc.args)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got handle=%q repo=%q branch=%q sec=%q", h, r, b, s)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if h != tc.wantHandle || r != tc.wantRepo || b != tc.wantBr || s != tc.wantSec {
				t.Fatalf("got (%q, %q, %q, %q), want (%q, %q, %q, %q)",
					h, r, b, s, tc.wantHandle, tc.wantRepo, tc.wantBr, tc.wantSec)
			}
		})
	}
}
