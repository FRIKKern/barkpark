package cli

// cloud_site_cmd_test.go proves `bp cloud site …` against a fake control plane:
// create POSTs the spawner body (kind + framework + dataset triple, Bearer-authed);
// deploy streams the six visible stages and lands on a live URL; a failed deploy
// exits non-zero with an honest "nothing switched" message; rollback names the
// atomic symlink flip and re-emits the CP envelope verbatim on -o json; status
// shows the current deployment + stage bar; open prints the live PATH url; and the
// arg parser + dispatcher reject the usual usage errors. The dataset-triple parser
// is unit-tested directly. A UUID site id means resolveOpenSiteID short-circuits,
// so the fake never needs to play GET /v1/sites.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// testSiteID is a valid UUID so resolveOpenSiteID passes it through without a
// fleet list call.
const testSiteID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

// siteCP is a recording fake control plane: it answers the spawner routes with
// caller-supplied bodies and records the last create request body + the auth
// header it saw, so a test can prove the wire contract (no vacuous green).
type siteCP struct {
	t          *testing.T
	createBody []byte
	lastAuth   string
	deployHits int
	pollHits   int
	// per-route responses (status, body)
	createResp  fakeResp
	deployResp  fakeResp
	pollResp    fakeResp
	getResp     fakeResp
	rollResp    fakeResp
}

type fakeResp struct {
	status int
	body   string
}

func newSiteCP(t *testing.T) *siteCP {
	return &siteCP{t: t}
}

// serve stands the fake up, seeds a cloud login pointed at it, and returns it.
func (cp *siteCP) serve() *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cp.lastAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		path := r.URL.Path
		switch {
		case r.Method == "POST" && path == "/v1/sites":
			cp.createBody, _ = io.ReadAll(r.Body)
			cp.write(w, cp.createResp)
		case r.Method == "POST" && path == "/v1/sites/"+testSiteID+"/deploy":
			cp.deployHits++
			cp.write(w, cp.deployResp)
		case r.Method == "GET" && strings.HasPrefix(path, "/v1/sites/"+testSiteID+"/deployments/"):
			cp.pollHits++
			cp.write(w, cp.pollResp)
		case r.Method == "POST" && path == "/v1/sites/"+testSiteID+"/rollback":
			cp.write(w, cp.rollResp)
		case r.Method == "GET" && path == "/v1/sites/"+testSiteID:
			cp.write(w, cp.getResp)
		default:
			cp.t.Fatalf("unexpected request %s %s", r.Method, path)
		}
	}))
	cp.t.Cleanup(srv.Close)
	withTempConfigHome(cp.t)
	seedCloudLogin(cp.t, srv.URL)
	return srv
}

func (cp *siteCP) write(w http.ResponseWriter, r fakeResp) {
	status := r.status
	if status == 0 {
		status = 200
	}
	w.WriteHeader(status)
	_, _ = w.Write([]byte(r.body))
}

// runSite drives runCloudSite with an in-memory writer at the chosen output
// shape. siteDeployPoll is forced to 0 so streaming tests never sleep.
func runSite(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	orig := siteDeployPoll
	siteDeployPoll = 0
	t.Cleanup(func() { siteDeployPoll = orig })
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudSite(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// --- parser unit test --------------------------------------------------------

func TestParseDatasetTriple(t *testing.T) {
	ws, proj, ds, err := parseDatasetTriple("acme/blog/production")
	if err != nil {
		t.Fatalf("valid triple errored: %v", err)
	}
	if ws != "acme" || proj != "blog" || ds != "production" {
		t.Fatalf("got %q/%q/%q, want acme/blog/production", ws, proj, ds)
	}
	for _, bad := range []string{"", "acme", "acme/blog", "acme/blog/prod/extra", "acme//prod", "/blog/prod"} {
		if _, _, _, err := parseDatasetTriple(bad); err == nil {
			t.Fatalf("parseDatasetTriple(%q) should have errored", bad)
		}
	}
}

// --- create ------------------------------------------------------------------

func TestRunCloudSiteCreate(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The request carried the spawner body: kind static, framework astro (default),
	// and the dataset triple — Bearer-authed.
	var got struct {
		Kind, Framework, Workspace, Project, Dataset, Name string
	}
	if err := json.Unmarshal(cp.createBody, &got); err != nil {
		t.Fatalf("decode create body: %v (raw %s)", err, cp.createBody)
	}
	if got.Name != "blog" || got.Kind != "static" || got.Framework != "astro" {
		t.Fatalf("create body kind/framework/name wrong: %+v", got)
	}
	if got.Workspace != "acme" || got.Project != "blog" || got.Dataset != "production" {
		t.Fatalf("create body dataset triple wrong: %+v", got)
	}
	if cp.lastAuth != "Bearer sess-abc" {
		t.Fatalf("auth=%q want the cloud bearer", cp.lastAuth)
	}
	if !strings.Contains(stdout, "site blog created") {
		t.Fatalf("missing create verdict:\n%s", stdout)
	}
	if !strings.Contains(stdout, "acme/blog/production") {
		t.Fatalf("create should echo the dataset triple:\n%s", stdout)
	}
}

func TestRunCloudSiteCreateJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--framework", "astro")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	var env struct {
		Site struct{ Kind, Dataset string } `json:"site"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json output not parseable: %v\n%s", err, stdout)
	}
	if env.Site.Kind != "static" || env.Site.Dataset != "production" {
		t.Fatalf("json site payload wrong: %+v", env.Site)
	}
}

func TestRunCloudSiteCreateUsage(t *testing.T) {
	withTempConfigHome(t)
	// missing --name / --dataset are usage errors BEFORE any network call.
	if _, _, code := runSite(t, "table", "create", "--dataset", "a/b/c"); code != exitUsage {
		t.Fatalf("missing --name exit=%d want %d", code, exitUsage)
	}
	if _, _, code := runSite(t, "table", "create", "--name", "x"); code != exitUsage {
		t.Fatalf("missing --dataset exit=%d want %d", code, exitUsage)
	}
	if _, _, code := runSite(t, "table", "create", "--name", "x", "--dataset", "a/b"); code != exitUsage {
		t.Fatalf("bad triple exit=%d want %d", code, exitUsage)
	}
}

// --- deploy (streamed stages) ------------------------------------------------

const sixStagesLive = `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"live","stage":"RETIRE","build_id":"b-1","url":"https://acme.barkpark.cloud/sites/blog/","stages":[` +
	`{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"},{"name":"STAGE","status":"done"},` +
	`{"name":"HEALTH","status":"done"},{"name":"SWITCH","status":"done"},{"name":"RETIRE","status":"done"}]}}`

func TestRunCloudSiteDeployStreamsStages(t *testing.T) {
	cp := newSiteCP(t)
	// deploy enqueues a queued build; the first poll returns the live deployment
	// with all six stages done.
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"b-1","stages":[{"name":"PLAN","status":"running"}]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 1 {
		t.Fatalf("deploy route hit %d times, want 1", cp.deployHits)
	}
	if cp.pollHits < 1 {
		t.Fatalf("stream never polled the deployment detail")
	}
	for _, stage := range []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"} {
		if !strings.Contains(stdout, stage) {
			t.Fatalf("stage %s not streamed:\n%s", stage, stdout)
		}
	}
	if !strings.Contains(stdout, "site live") || !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("missing live verdict + url:\n%s", stdout)
	}
}

func TestRunCloudSiteDeployFailed(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"failed","stage":"HEALTH","failure_reason":"health probe returned 500","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"},{"name":"STAGE","status":"done"},{"name":"HEALTH","status":"failed"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d (build failed)\n%s", code, exitGeneric, stderr)
	}
	if !strings.Contains(stderr, "HEALTH") || !strings.Contains(stderr, "health probe returned 500") {
		t.Fatalf("failure must name the stage + reason:\n%s", stderr)
	}
	if strings.Contains(stdout, "site live") {
		t.Fatalf("a failed deploy must not claim live:\n%s", stdout)
	}
}

func TestRunCloudSiteDeployJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()
	stdout, _, code := runSite(t, "json", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	var env struct {
		Deployment struct {
			Status string
			Stages []struct{ Name, Status string }
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment.Status != "live" || len(env.Deployment.Stages) != 6 {
		t.Fatalf("json deployment wrong: %+v", env.Deployment)
	}
}

func TestRunCloudSiteDeployNoFollow(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[{"name":"PLAN","status":"running"}]}}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "deploy", testSiteID, "--no-follow")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if cp.pollHits != 0 {
		t.Fatalf("--no-follow must not poll the deployment detail (hit %d)", cp.pollHits)
	}
	if !strings.Contains(stdout, "in progress") {
		t.Fatalf("--no-follow should print the in-progress verdict:\n%s", stdout)
	}
}

// --- rollback ----------------------------------------------------------------

const rollbackEnvelope = `{"ok":true,"status":"rolled_back","deployment_id":"dep-prev","previous_deployment_id":"dep-1","url":"https://acme.barkpark.cloud/sites/blog/"}`

func TestRunCloudSiteRollback(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{200, rollbackEnvelope}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "rollback", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "rolled back") || !strings.Contains(stdout, "dep-prev") {
		t.Fatalf("missing rollback verdict + new deployment:\n%s", stdout)
	}
	if !strings.Contains(stdout, "atomic symlink") {
		t.Fatalf("rollback copy must name the atomic symlink flip:\n%s", stdout)
	}
}

func TestRunCloudSiteRollbackJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{200, rollbackEnvelope}
	cp.serve()
	stdout, _, code := runSite(t, "json", "rollback", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if strings.TrimSpace(stdout) != rollbackEnvelope {
		t.Fatalf("json must re-emit the CP envelope verbatim:\n got %q\nwant %q", stdout, rollbackEnvelope)
	}
}

// --- status ------------------------------------------------------------------

func TestRunCloudSiteStatus(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/","current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"}]}}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "live") || !strings.Contains(stdout, "stages:") {
		t.Fatalf("status must show deployment status + stage bar:\n%s", stdout)
	}
	// The full six-stage bar is shown even though the payload sent two — the
	// omitted ones fill as pending.
	for _, stage := range []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"} {
		if !strings.Contains(stdout, stage) {
			t.Fatalf("stage %s missing from status bar:\n%s", stage, stdout)
		}
	}
}

func TestRunCloudSiteStatusNeverDeployed(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if !strings.Contains(stdout, "no deployment yet") {
		t.Fatalf("honest empty state missing:\n%s", stdout)
	}
}

// --- open --------------------------------------------------------------------

func TestRunCloudSiteOpen(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","slug":"blog","url":"https://acme.barkpark.cloud/sites/blog/"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "open", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if strings.TrimSpace(stdout) != "https://acme.barkpark.cloud/sites/blog/" {
		t.Fatalf("open must print the live PATH url bare:\n%q", stdout)
	}
}

func TestRunCloudSiteOpenDerivesURL(t *testing.T) {
	cp := newSiteCP(t)
	// no url — derive from instance host + slug.
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","slug":"blog","instance":"acme"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "open", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("open should derive the PATH url from instance+slug:\n%s", stdout)
	}
}

func TestRunCloudSiteOpenNoURL(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","slug":"blog"}}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "open", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d (no url yet)", code, exitGeneric)
	}
	if !strings.Contains(stderr, "no live URL yet") {
		t.Fatalf("open should explain there is no url yet:\n%s", stderr)
	}
}

// --- dispatch / auth / help --------------------------------------------------

func TestRunCloudSiteUnknownVerb(t *testing.T) {
	withTempConfigHome(t)
	if _, _, code := runSite(t, "table", "frobnicate"); code != exitUsage {
		t.Fatalf("unknown verb exit=%d want %d", code, exitUsage)
	}
	if _, _, code := runSite(t, "table"); code != exitUsage {
		t.Fatalf("no verb exit=%d want %d", code, exitUsage)
	}
}

func TestRunCloudSiteNoToken(t *testing.T) {
	withTempConfigHome(t) // logged out
	for _, verb := range [][]string{
		{"create", "--name", "x", "--dataset", "a/b/c"},
		{"deploy", testSiteID},
		{"rollback", testSiteID},
		{"status", testSiteID},
		{"open", testSiteID},
	} {
		_, stderr, code := runSite(t, "table", verb...)
		if code != exitAuth {
			t.Fatalf("%v exit=%d want %d (auth)", verb, code, exitAuth)
		}
		if !strings.Contains(stderr, "bp login") {
			t.Fatalf("%v should hint bp login:\n%s", verb, stderr)
		}
	}
}

func TestRunCloudSiteHelp(t *testing.T) {
	withTempConfigHome(t)
	stdout, _, code := runSite(t, "table", "-h")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if !strings.Contains(stdout, "bp cloud site") {
		t.Fatalf("help must name the command:\n%s", stdout)
	}
	// The help must distinguish the spawned-site verbs from instance ops and the
	// container model so the three never blur.
	if !strings.Contains(stdout, "bp cloud deploy") || !strings.Contains(stdout, "bp sites") {
		t.Fatalf("help must distinguish from instance + container deploy:\n%s", stdout)
	}
}

// TestRunCloudSiteDispatchedFromRunCloud proves the new `site` case is wired into
// runCloud (and its `sites` alias) — the charter-D10 dispatcher seam.
func TestRunCloudSiteDispatchedFromRunCloud(t *testing.T) {
	withTempConfigHome(t)
	for _, verb := range []string{"site", "sites"} {
		var sout, serr bytes.Buffer
		w := newWriter(&sout, &serr)
		w.output = "table"
		code := runCloud(w, globals{}, []string{verb, "-h"})
		if code != exitOK {
			t.Fatalf("runCloud %s -h exit=%d want 0", verb, code)
		}
		if !strings.Contains(sout.String(), "bp cloud site") {
			t.Fatalf("runCloud %s did not reach the site help:\n%s", verb, sout.String())
		}
	}
}
