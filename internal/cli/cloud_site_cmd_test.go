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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// testSiteID is a valid UUID so resolveOpenSiteID passes it through without a
// fleet list call.
const testSiteID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

// --instance is MANDATORY on create; the package-level testInstanceID (declared in
// cloud_webhook_cmd_test.go) is a valid UUID, so resolveOpenBarkparkID passes it
// through without a fleet-list call.

// siteCP is a recording fake control plane: it answers the spawner routes with
// caller-supplied bodies and records the last create request body + the auth
// header it saw, so a test can prove the wire contract (no vacuous green).
type siteCP struct {
	t          *testing.T
	createBody []byte
	deployBody []byte
	lastAuth   string
	deployHits int
	pollHits   int
	// per-route responses (status, body)
	createResp fakeResp
	deployResp fakeResp
	pollResp   fakeResp
	getResp    fakeResp
	rollResp   fakeResp
	deleteResp fakeResp
	// GET /v1/sites/:id/deployments — the newest-first LIST `status` reads to
	// learn whether the live pointer is also the last thing that happened.
	// listQuery records the raw query so a test can prove the bound was sent.
	listResp  fakeResp
	listHits  int
	listQuery string
	// PATCH /v1/sites/:id — `bp cloud site settings` (search-template W8/W10).
	patchResp fakeResp
	patchBody []byte
	// POST /v1/sites/:id/deployments/:dep/artifact — the prebuilt lane's second
	// call. The recorded Content-Length is the point of the test: a piped upload
	// arrives chunked (-1) and the server cannot reject it early.
	artifactResp   fakeResp
	artifactHits   int
	artifactBody   []byte
	artifactLen    int64
	artifactSha    string
	artifactPath   string
	artifactChunks bool
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
			cp.deployBody, _ = io.ReadAll(r.Body)
			cp.write(w, cp.deployResp)
		case r.Method == "POST" && strings.HasPrefix(path, "/v1/sites/"+testSiteID+"/deployments/") && strings.HasSuffix(path, "/artifact"):
			cp.artifactHits++
			cp.artifactPath = path
			cp.artifactLen = r.ContentLength
			cp.artifactChunks = len(r.TransferEncoding) > 0
			cp.artifactSha = r.Header.Get("X-Artifact-Sha256")
			cp.artifactBody, _ = io.ReadAll(r.Body)
			cp.write(w, cp.artifactResp)
		case r.Method == "GET" && strings.HasPrefix(path, "/v1/sites/"+testSiteID+"/deployments/"):
			cp.pollHits++
			cp.write(w, cp.pollResp)
		// The LIST route (no trailing slash) — `bp cloud site status`'s second read.
		// The poll case above matches ".../deployments/" WITH the slash, so before
		// this case a bare list GET fell to the default arm and t.Fatal'd every
		// status test. Default body is an empty page, which is what a site with no
		// deployments returns and what every pre-existing test wants.
		case r.Method == "GET" && path == "/v1/sites/"+testSiteID+"/deployments":
			cp.listHits++
			cp.listQuery = r.URL.RawQuery
			if cp.listResp.body == "" && cp.listResp.status == 0 {
				cp.write(w, fakeResp{200, `{"deployments":[],"next_cursor":null}`})
				break
			}
			cp.write(w, cp.listResp)
		case r.Method == "POST" && path == "/v1/sites/"+testSiteID+"/rollback":
			cp.write(w, cp.rollResp)
		case r.Method == "DELETE" && path == "/v1/sites/"+testSiteID:
			cp.write(w, cp.deleteResp)
		case r.Method == "PATCH" && path == "/v1/sites/"+testSiteID:
			cp.patchBody, _ = io.ReadAll(r.Body)
			cp.write(w, cp.patchResp)
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

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The request carried the spawner body: kind static, framework astro (default),
	// the dataset triple, and the mandatory barkpark id — Bearer-authed.
	var got struct {
		Kind, Framework, Workspace, Project, Dataset, Name string
		BarkparkID                                         string `json:"barkpark_id"`
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
	// sites.barkpark_id is NOT NULL server-side: the body must always carry it.
	if got.BarkparkID != testInstanceID {
		t.Fatalf("create body barkpark_id=%q want %q", got.BarkparkID, testInstanceID)
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
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--framework", "astro", "--instance", testInstanceID)
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

// TestRunCloudSiteCreateDocType is the D35 plumbing proof: --doc-type reaches the
// wire as doc_type so a dataset that serves a non-default type (guerrilla is
// `paper`, not `post`) actually builds. Passing it via an env prefix is inert —
// the box's allowlist drops it — so create is the ONLY channel that gets it there.
func TestRunCloudSiteCreateDocType(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID, "--doc-type", "paper")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var got struct {
		DocType string `json:"doc_type"`
	}
	if err := json.Unmarshal(cp.createBody, &got); err != nil {
		t.Fatalf("decode create body: %v (raw %s)", err, cp.createBody)
	}
	if got.DocType != "paper" {
		t.Fatalf("create body doc_type=%q want %q (raw %s)", got.DocType, "paper", cp.createBody)
	}
	if !strings.Contains(stdout, "paper") {
		t.Fatalf("create should echo the doc type it bound:\n%s", stdout)
	}
}

// TestRunCloudSiteCreateDocTypeOmitted proves the field is omitempty: with no
// --doc-type the wire carries NO doc_type key at all, so the control plane applies
// its own canonical default ("post") rather than the CLI forcing an empty string.
func TestRunCloudSiteCreateDocTypeOmitted(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static"}}`}
	cp.serve()
	if _, _, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID); code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if bytes.Contains(cp.createBody, []byte("doc_type")) {
		t.Fatalf("omitted --doc-type must not send a doc_type key (omitempty): %s", cp.createBody)
	}
}

// TestRunCloudSiteCreateNode is the D62 node-slot surface proof: `--kind node
// --framework nextjs` threads kind=node + framework=nextjs to the wire, and the
// created-site verdict narrates the node-slot SSR runtime (a long-running process
// on a slot port) rather than the static astro-flagship note.
func TestRunCloudSiteCreateNode(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"node","framework":"nextjs","workspace":"acme","project":"app","dataset":"production","runtime_target":"node-slot","port":4301,"port_base":4300}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "app", "--dataset", "acme/app/production", "--instance", testInstanceID, "--kind", "node", "--framework", "nextjs")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The wire carried the node discriminators, Bearer-authed.
	var got struct {
		Kind, Framework string
	}
	if err := json.Unmarshal(cp.createBody, &got); err != nil {
		t.Fatalf("decode create body: %v (raw %s)", err, cp.createBody)
	}
	if got.Kind != "node" || got.Framework != "nextjs" {
		t.Fatalf("create body kind/framework wrong: %+v (raw %s)", got, cp.createBody)
	}
	// The verdict narrates the node-slot runtime, not the astro flagship note.
	if !strings.Contains(stdout, "node") || !strings.Contains(stdout, "SSR process") {
		t.Fatalf("node create should narrate the node-slot SSR runtime:\n%s", stdout)
	}
	if strings.Contains(stdout, "astro is the flagship") {
		t.Fatalf("a node site must not print the static astro-flagship note:\n%s", stdout)
	}
}

// TestRunCloudSiteStatusNodeFields is the json.Unmarshal-drops-unknown-keys proof:
// the server returns runtime_target / port / port_base on a node site, and both the
// human status header and `-o json` must SURFACE them (they were invisible until
// SpawnSite + spawnSiteMap threaded the fields).
func TestRunCloudSiteStatusNodeFields(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"node","framework":"nextjs","workspace":"acme","project":"app","dataset":"production","runtime_target":"node-slot","port":4301,"port_base":4300,"url":"https://acme.barkpark.cloud/sites/app/","current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","runtime_target":"node-slot","port":4301,"stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	// The human header surfaces the node runtime + the live slot port.
	if !strings.Contains(stdout, "node-slot") || !strings.Contains(stdout, "4301") {
		t.Fatalf("node status header must show runtime + port:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Site struct {
			RuntimeTarget string `json:"runtime_target"`
			Port          int    `json:"port"`
			PortBase      int    `json:"port_base"`
		} `json:"site"`
		Deployment struct {
			RuntimeTarget string `json:"runtime_target"`
			Port          int    `json:"port"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if env.Site.RuntimeTarget != "node-slot" || env.Site.Port != 4301 || env.Site.PortBase != 4300 {
		t.Fatalf("status -o json dropped the node site fields: %+v\n%s", env.Site, jstdout)
	}
	if env.Deployment.RuntimeTarget != "node-slot" || env.Deployment.Port != 4301 {
		t.Fatalf("status -o json dropped the node deployment fields: %+v\n%s", env.Deployment, jstdout)
	}
}

// TestRunCloudSiteDocTypeReadback is the W10 readback proof, modelled on
// TestRunCloudSiteStatusNodeFields: doc_type is writable at create and at
// PATCH, and until now no CLI surface echoed it. It must land on ALL THREE
// projections — `-o json`, the human status table, and the settings narration.
// A json-only assertion would pass while the other two stayed blind, which is
// exactly how the gap survived.
func TestRunCloudSiteDocTypeReadback(t *testing.T) {
	const siteJSON = `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","template":"search","theme":"ember","doc_type":"paper","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/"}}`
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, siteJSON}
	cp.patchResp = fakeResp{200, siteJSON}
	cp.serve()

	// 1. `-o json` — the key exists and carries the value (SpawnSite.DocType must
	// be declared or json.Unmarshal drops it here, silently, with exit 0).
	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Site struct {
			DocType *string `json:"doc_type"`
		} `json:"site"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if env.Site.DocType == nil {
		t.Fatalf("status -o json omitted doc_type entirely (silent drop):\n%s", jstdout)
	}
	if *env.Site.DocType != "paper" {
		t.Fatalf("status -o json doc_type=%q want %q\n%s", *env.Site.DocType, "paper", jstdout)
	}

	// 2. The human status table — a separate map (spawnSiteStatusMap) that
	// carries neither template nor theme, so json alone leaves it blank.
	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("status exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "doc type") || !strings.Contains(stdout, "paper") {
		t.Fatalf("status table must show the doc type row:\n%s", stdout)
	}

	// 3. The settings narration — `--doc-type` echoed theme and starter and never
	// the field it just set.
	sstdout, sstderr, scode := runSite(t, "table", "settings", testSiteID, "--doc-type", "paper")
	if scode != exitOK {
		t.Fatalf("settings exit=%d want 0\n%s", scode, sstderr)
	}
	if !bytes.Contains(cp.patchBody, []byte(`"doc_type":"paper"`)) {
		t.Fatalf("settings must PATCH doc_type: %s", cp.patchBody)
	}
	if !strings.Contains(sstdout, "paper") {
		t.Fatalf("settings narration must echo the doc_type it just set:\n%s", sstdout)
	}
}

// TestRunCloudSiteDocTypeAbsent proves the guarded surfaces stay silent against a
// pre-W10 control plane (no doc_type key at all): no invented default in the
// table or the narration, while `-o json` still always-echoes the key like
// template/theme do — an empty string, honestly.
func TestRunCloudSiteDocTypeAbsent(t *testing.T) {
	const siteJSON = `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, siteJSON}
	cp.serve()

	stdout, _, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("status exit=%d want 0", code)
	}
	if strings.Contains(stdout, "doc type") {
		t.Fatalf("a pre-W10 control plane must not grow a doc type row:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Site struct {
			DocType *string `json:"doc_type"`
		} `json:"site"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if env.Site.DocType == nil || *env.Site.DocType != "" {
		t.Fatalf("json must always-echo doc_type as an honest empty string: %+v\n%s", env.Site, jstdout)
	}
}

// TestRunCloudSiteRollbackNode is the mechanism-branch proof (D62): a node
// rollback envelope carries runtime_target="node-slot", so the narration must name
// the Caddy upstream port-flip to the warm previous slot — NOT the atomic symlink
// swap, which is false for a node site.
func TestRunCloudSiteRollbackNode(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{200, `{"ok":true,"status":"rolled_back","deployment_id":"dep-prev","previous_deployment_id":"dep-1","runtime_target":"node-slot","port":4300,"url":"https://acme.barkpark.cloud/sites/app/"}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "rollback", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "Caddy upstream") || !strings.Contains(stdout, "warm") {
		t.Fatalf("node rollback must narrate the Caddy upstream port-flip:\n%s", stdout)
	}
	if strings.Contains(stdout, "atomic symlink") {
		t.Fatalf("a node rollback must NOT claim an atomic symlink swap:\n%s", stdout)
	}
}

// TestRunCloudSiteDeployNodeJSON proves the deploy stream's `-o json` surfaces the
// node runtime_target/port the server stamped on the deployment — they would be
// silently dropped without SiteDeployment carrying the fields.
func TestRunCloudSiteDeployNodeJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"live","stage":"RETIRE","build_id":"b-1","runtime_target":"node-slot","port":4301,"url":"https://acme.barkpark.cloud/sites/app/","stages":[` +
		`{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"},{"name":"STAGE","status":"done"},` +
		`{"name":"HEALTH","status":"done"},{"name":"SWITCH","status":"done"},{"name":"RETIRE","status":"done"}]}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	var env struct {
		Deployment struct {
			RuntimeTarget string `json:"runtime_target"`
			Port          int    `json:"port"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment.RuntimeTarget != "node-slot" || env.Deployment.Port != 4301 {
		t.Fatalf("deploy -o json dropped the node fields: %+v\n%s", env.Deployment, stdout)
	}
}

func TestRunCloudSiteCreateUsage(t *testing.T) {
	withTempConfigHome(t)
	// missing --name / --dataset are usage errors BEFORE any network call.
	if _, _, code := runSite(t, "table", "create", "--dataset", "a/b/c", "--instance", testInstanceID); code != exitUsage {
		t.Fatalf("missing --name exit=%d want %d", code, exitUsage)
	}
	if _, _, code := runSite(t, "table", "create", "--name", "x", "--instance", testInstanceID); code != exitUsage {
		t.Fatalf("missing --dataset exit=%d want %d", code, exitUsage)
	}
	if _, _, code := runSite(t, "table", "create", "--name", "x", "--dataset", "a/b", "--instance", testInstanceID); code != exitUsage {
		t.Fatalf("bad triple exit=%d want %d", code, exitUsage)
	}
}

// TestRunCloudSiteCreateRequiresInstance is the D29 honesty fix: sites.barkpark_id
// is validate_required AND NOT NULL, and nothing in the control plane derives an
// instance from the workspace — so a create with no --instance must fail HERE, with
// an error that names how to find one, and must never reach the wire (where the
// server answers with a misleading `name_required` 422).
func TestRunCloudSiteCreateRequiresInstance(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production")
	if code != exitUsage {
		t.Fatalf("create without --instance exit=%d want %d (usage)\nstdout:%s\nstderr:%s", code, exitUsage, stdout, stderr)
	}
	if cp.createBody != nil {
		t.Fatalf("create without --instance must not hit the wire, but POSTed: %s", cp.createBody)
	}
	if !strings.Contains(stderr, "--instance is required") {
		t.Fatalf("missing the required-flag error:\n%s", stderr)
	}
	// Actionable: it names where to find an instance.
	if !strings.Contains(stderr, "bp cloud instances") || !strings.Contains(stderr, "bp cloud status") {
		t.Fatalf("the error must name how to list instances:\n%s", stderr)
	}
}

// TestSiteCreateHasNoWorkspaceResolutionClaim is the tripwire on the deleted lie:
// neither the CLI nor the cloud client may claim that the server derives an instance
// from the workspace — no such resolution exists anywhere in the control plane, and
// a comment that says otherwise is how the bug got written in the first place. This
// reads the source, so re-introducing the sentence fails the build's own test.
func TestSiteCreateHasNoWorkspaceResolutionClaim(t *testing.T) {
	lies := []string{
		"picks the instance from the workspace",
		"resolves the target instance from the workspace",
		"instance from the workspace; the CLI",
	}
	for _, src := range []string{"cloud_site_cmd.go", "../cloudclient/client.go"} {
		b, err := os.ReadFile(src)
		if err != nil {
			t.Fatalf("read %s: %v", src, err)
		}
		body := string(b)
		for _, lie := range lies {
			if strings.Contains(body, lie) {
				t.Fatalf("%s still carries the false claim %q — the control plane never resolves an instance from the workspace", src, lie)
			}
		}
	}
}

// TestRunCloudSiteCreateDeployMotion is the D19 one-motion proof: `create --deploy`
// chains CLIENT-SIDE straight into the deploy stream — one POST /v1/sites, then one
// POST …/deploy, then the poll — and ends on the live URL, narrating the six visible
// stages along the way. The create summary rides progressf so it never crashes into
// the deploy verdict.
func TestRunCloudSiteCreateDeployMotion(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"b-1","stages":[{"name":"PLAN","status":"running"}]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID, "--deploy")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// One create, one deploy enqueue, at least one poll — the full one-motion.
	if cp.deployHits != 1 {
		t.Fatalf("create --deploy must enqueue exactly one deploy, hit %d", cp.deployHits)
	}
	if cp.pollHits < 1 {
		t.Fatalf("create --deploy must stream the deploy (never polled)")
	}
	// The create verdict AND the deploy stages are both narrated.
	if !strings.Contains(stdout, "site blog created") {
		t.Fatalf("one-motion must still print the create verdict:\n%s", stdout)
	}
	for _, stage := range []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"} {
		if !strings.Contains(stdout, stage) {
			t.Fatalf("stage %s not streamed by create --deploy:\n%s", stage, stdout)
		}
	}
	// It ends on the live URL — not the `deploy it with …` hint a plain create prints.
	if !strings.Contains(stdout, "site live") || !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("one-motion must end on the live URL:\n%s", stdout)
	}
	if strings.Contains(stdout, "deploy it with") {
		t.Fatalf("create --deploy must NOT print the separate-deploy hint:\n%s", stdout)
	}
}

// TestRunCloudSiteCreateDeployJSON proves the one-motion honours the single-envelope
// contract: with -o json the create summary rides stderr (progressf) and stdout is
// exactly the deployment envelope the deploy stream owns.
func TestRunCloudSiteCreateDeployJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID, "--deploy")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	// stdout is a single parseable envelope — the deployment, not the site.
	var env struct {
		Deployment struct {
			Status string
			Stages []struct{ Name, Status string }
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("one-motion -o json must be a single deployment envelope: %v\n%s", err, stdout)
	}
	if env.Deployment.Status != "live" || len(env.Deployment.Stages) != 6 {
		t.Fatalf("one-motion json deployment wrong: %+v", env.Deployment)
	}
}

// TestRunCloudSiteCreateDeployInstanceNotLive is the honest instance-still-provisioning
// path: the box answers the chained deploy with a 422 instance_not_live, and because
// the site IS created the CLI says exactly that and points at the retry command — it
// never crashes, never claims live, and never dumps a bare error slug.
func TestRunCloudSiteCreateDeployInstanceNotLive(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.deployResp = fakeResp{422, `{"error":"instance_not_live","detail":"the instance is still provisioning"}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID, "--deploy")
	if code != exitGeneric {
		t.Fatalf("instance-not-live exit=%d want %d\nstdout:%s\nstderr:%s", code, exitGeneric, stdout, stderr)
	}
	// The site was created and the deploy was attempted once — no retry storm.
	if cp.deployHits != 1 {
		t.Fatalf("instance-not-live should attempt the deploy exactly once, hit %d", cp.deployHits)
	}
	if cp.pollHits != 0 {
		t.Fatalf("a rejected deploy must never poll (hit %d)", cp.pollHits)
	}
	// The honest message: the site exists, the instance is provisioning, here's the retry.
	if !strings.Contains(stderr, "still provisioning") {
		t.Fatalf("instance-not-live must say the instance is still provisioning:\n%s", stderr)
	}
	if !strings.Contains(stderr, "bp cloud site deploy") {
		t.Fatalf("instance-not-live must point at the retry command:\n%s", stderr)
	}
	if strings.Contains(stdout, "site live") {
		t.Fatalf("instance-not-live must never claim the site is live:\n%s", stdout)
	}
}

// TestRunCloudSiteCreateNoDeployKeepsHint is the tripwire on the unchanged default:
// without --deploy, create prints the separate-deploy hint and NEVER touches the
// deploy route — so the 30+ pinned deploy tests stay green and a plain create is
// byte-identical.
func TestRunCloudSiteCreateNoDeployKeepsHint(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if cp.deployHits != 0 {
		t.Fatalf("a plain create must never hit the deploy route (hit %d)", cp.deployHits)
	}
	if !strings.Contains(stdout, "deploy it with `bp cloud site deploy blog`") {
		t.Fatalf("plain create must print the separate-deploy hint:\n%s", stdout)
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

// TestRunCloudSiteDeployForce is the D36 proof: --force POSTs {"force":true} to
// the deploy route so the box folds a nonce and mints a genuinely new release even
// when content+config are unchanged. Without it a re-deploy would return the
// cached (possibly failed) deployment and could never re-run.
func TestRunCloudSiteDeployForce(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-2","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	if _, stderr, code := runSite(t, "table", "deploy", testSiteID, "--force"); code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	var got struct {
		Force bool `json:"force"`
	}
	if err := json.Unmarshal(cp.deployBody, &got); err != nil {
		t.Fatalf("decode deploy body: %v (raw %s)", err, cp.deployBody)
	}
	if !got.Force {
		t.Fatalf("--force must POST {\"force\":true}, got %s", cp.deployBody)
	}
}

// TestRunCloudSiteDeployNoForce is the tripwire on the idempotent default: with no
// --force the deploy body must NOT carry force:true, so an unchanged re-deploy
// stays the byte-identical no-op the box relies on.
func TestRunCloudSiteDeployNoForce(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	if _, _, code := runSite(t, "table", "deploy", testSiteID); code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if bytes.Contains(cp.deployBody, []byte("true")) {
		t.Fatalf("a plain deploy must not send force:true, got %s", cp.deployBody)
	}
}

// TestRunCloudSiteDeployContentAutoTrigger is the D49 provenance proof for a
// content-fired rebuild: when the control plane stamps trigger="content-auto"
// (a publish on the bound dataset kicked the debounced auto-deploy), the stream
// narrates the auto label on the queued and live lines, and `-o json` surfaces
// the trigger so a script can tell an auto-rebuild from a hand-run deploy.
func TestRunCloudSiteDeployContentAutoTrigger(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"b-1","trigger":"content-auto","stages":[{"name":"PLAN","status":"running"}]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"live","stage":"RETIRE","build_id":"b-1","trigger":"content-auto","url":"https://acme.barkpark.cloud/sites/blog/","stages":[` +
		`{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"},{"name":"STAGE","status":"done"},` +
		`{"name":"HEALTH","status":"done"},{"name":"SWITCH","status":"done"},{"name":"RETIRE","status":"done"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "auto: content publish") {
		t.Fatalf("content-auto deploy must narrate the auto provenance:\n%s", stdout)
	}

	// -o json must carry the trigger — Go's Unmarshal drops unknown keys, so this
	// fails until SiteDeployment.Trigger + siteDeploymentMap thread it through.
	jstdout, _, jcode := runSite(t, "json", "deploy", testSiteID)
	if jcode != exitOK {
		t.Fatalf("json exit=%d want 0", jcode)
	}
	var env struct {
		Deployment struct {
			Trigger string `json:"trigger"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, jstdout)
	}
	if env.Deployment.Trigger != "content-auto" {
		t.Fatalf("json deployment.trigger = %q, want content-auto\n%s", env.Deployment.Trigger, jstdout)
	}
}

// TestRunCloudSiteDeployManualTriggerNoAutoLabel is the complement: a hand-run
// deploy (trigger="manual") says "manual", never the content-auto label — the
// provenance must not lie in the other direction either.
func TestRunCloudSiteDeployManualTriggerNoAutoLabel(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"b-1","trigger":"manual","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if strings.Contains(stdout, "auto: content publish") {
		t.Fatalf("a manual deploy must NOT claim content-auto provenance:\n%s", stdout)
	}
	if !strings.Contains(stdout, "manual") {
		t.Fatalf("a manual deploy should narrate its manual provenance:\n%s", stdout)
	}
}

// TestRunCloudSiteStatusShowsTrigger proves the human status table surfaces the
// deploy provenance (D49) — a user checking `bp cloud site status` sees whether
// the live build came from a publish or a manual run, and `-o json` carries it.
func TestRunCloudSiteStatusShowsTrigger(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/","current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","trigger":"content-auto","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"done"}]}}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "trigger") || !strings.Contains(stdout, "content publish (auto)") {
		t.Fatalf("status table must surface the deploy trigger:\n%s", stdout)
	}

	jstdout, _, _ := runSite(t, "json", "status", testSiteID)
	var env struct {
		Deployment struct {
			Trigger string `json:"trigger"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, jstdout)
	}
	if env.Deployment.Trigger != "content-auto" {
		t.Fatalf("status -o json deployment.trigger = %q, want content-auto\n%s", env.Deployment.Trigger, jstdout)
	}
}

// TestRunCloudSiteDeployNarratesRunningThenDone is the D39 proof: a stage that
// walks running → done prints TWO distinct lines (the "started" narration then the
// terminal line), and the terminal done-line is NEVER swallowed. The bug D39 kills
// is a name-only printed map: once "… BUILD" is printed, "✓ BUILD" would be
// skipped and the bar would never resolve. Keyed by (name+status), BUILD appears
// exactly twice — once running, once done — never once, never thrice.
func TestRunCloudSiteDeployNarratesRunningThenDone(t *testing.T) {
	cp := newSiteCP(t)
	// The queued deploy response already carries BUILD as running (the box streams
	// `started` as status running) — render() prints it on the first pass.
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"building","stage":"BUILD","build_id":"b-1","stages":[{"name":"BUILD","status":"running"}]}}`}
	// The poll lands live with BUILD done among all six.
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// BUILD gets exactly two stream lines: no swallow (done survives), no double
	// (running is not reprinted on every poll).
	if n := strings.Count(stdout, "BUILD"); n != 2 {
		t.Fatalf("BUILD should appear exactly twice (running + done), got %d:\n%s", n, stdout)
	}
	// One line carries the running glyph, one the done glyph — the two transitions.
	if !strings.Contains(stdout, siteStageMark("running")+" "+hzCell("BUILD")) {
		t.Fatalf("missing the running BUILD line:\n%s", stdout)
	}
	if !strings.Contains(stdout, siteStageMark("done")+" "+hzCell("BUILD")) {
		t.Fatalf("missing the terminal (done) BUILD line — it was swallowed:\n%s", stdout)
	}
}

// TestRunCloudSiteDeployCancelled is the D30 honesty fix: `cancelled` is one of the
// six real deployment statuses and IS terminal. Before, only live|failed were, so a
// cancelled deploy polled its full 300×2s budget (~10 min) and then printed "deploy
// in progress". Now: the stream stops on the FIRST poll, says it was cancelled, and
// exits non-zero.
func TestRunCloudSiteDeployCancelled(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[{"name":"PLAN","status":"done"}]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"cancelled","stage":"BUILD","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"skipped","detail":"cancelled by operator"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code == exitOK {
		t.Fatalf("a cancelled deploy must not exit 0\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	// Terminal on the FIRST poll — not 300 of them.
	if cp.pollHits != 1 {
		t.Fatalf("cancelled polled %d times, want exactly 1 (terminal on first read)", cp.pollHits)
	}
	if !strings.Contains(stderr, "cancelled") {
		t.Fatalf("the verdict must say the deploy was cancelled:\n%s", stderr)
	}
	if strings.Contains(stdout, "in progress") || strings.Contains(stdout, "site live") {
		t.Fatalf("a cancelled deploy must claim neither progress nor liveness:\n%s", stdout)
	}
}

// TestRunCloudSiteDeployCancelledJSON proves the machine path agrees with the human
// one: -o json still emits the envelope, and the exit code is non-zero, so a script
// that checks $? never treats a cancelled deploy as a shipped one.
func TestRunCloudSiteDeployCancelledJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"cancelled","stage":"BUILD","stages":[]}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("cancelled -o json exit=%d want %d", code, exitGeneric)
	}
	var env struct {
		Deployment struct{ Status string } `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment.Status != "cancelled" {
		t.Fatalf("json deployment status=%q want cancelled", env.Deployment.Status)
	}
}

// TestRunCloudSiteDeployStreamsStageDetail proves the per-stage `detail` the deploy
// engine streams reaches the user's screen — both on the stage lines and, when the
// deployment carries no failure_reason of its own, as the failure verdict. The canned
// fallback must NOT bury the real reason.
func TestRunCloudSiteDeployStreamsStageDetail(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	// No failure_reason at the deployment level — the truth lives in the stage detail.
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"failed","stage":"HEALTH","stages":[` +
		`{"name":"PLAN","status":"done","detail":"build b-1 from content rev r7"},` +
		`{"name":"BUILD","status":"done","detail":"astro build in 1.7s"},` +
		`{"name":"STAGE","status":"done","detail":"12K into releases/b-1"},` +
		`{"name":"HEALTH","status":"failed","detail":"probe got 500 on / (marker bp-build-id absent)"},` +
		`{"name":"SWITCH","status":"skipped","detail":"not switched — previous build still live"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d (failed)", code, exitGeneric)
	}
	// Every stage's detail is streamed alongside its marker.
	for _, want := range []string{"astro build in 1.7s", "12K into releases/b-1", "probe got 500 on /", "not switched"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stage detail %q not streamed:\n%s", want, stdout)
		}
	}
	// The failure verdict quotes the real reason, not the canned health-gate line.
	if !strings.Contains(stderr, "probe got 500 on /") {
		t.Fatalf("failure verdict must carry the failed stage's detail:\n%s", stderr)
	}
	if strings.Contains(stderr, "did not pass its health gate") {
		t.Fatalf("the canned fallback must not mask a real reason:\n%s", stderr)
	}
	if !strings.Contains(stderr, "HEALTH") {
		t.Fatalf("failure verdict must name the stage:\n%s", stderr)
	}
}

// TestRunCloudSiteDeployFallbackWhenServerSaysNothing keeps the fallback honest: when
// neither failure_reason nor a stage detail exists, the CLI still explains that
// nothing was switched — it never invents a reason.
func TestRunCloudSiteDeployFallbackWhenServerSaysNothing(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"failed","stages":[]}}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d", code, exitGeneric)
	}
	if !strings.Contains(stderr, "visitors still see the previous build") {
		t.Fatalf("bare failure must still be honest about the blast radius:\n%s", stderr)
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

// --- delete ------------------------------------------------------------------

const deleteEnvelope = `{"ok":true,"status":"deleted","slug":"blog"}`

func TestRunCloudSiteDelete(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{200, deleteEnvelope}
	cp.serve()
	// --yes skips the TTY confirm deterministically.
	stdout, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "deleted") || !strings.Contains(stdout, "blog") {
		t.Fatalf("delete receipt must confirm the site is gone:\n%s", stdout)
	}
}

func TestRunCloudSiteDeleteJSON(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{200, deleteEnvelope}
	cp.serve()
	stdout, _, code := runSite(t, "json", "delete", testSiteID, "--yes")
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if strings.TrimSpace(stdout) != deleteEnvelope {
		t.Fatalf("json must re-emit the CP envelope verbatim:\n got %q\nwant %q", stdout, deleteEnvelope)
	}
}

// A teardown the box refused is a non-2xx from the CP → the CLI must exit
// non-zero and NEVER print a false "deleted".
func TestRunCloudSiteDeleteTeardownRefused(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{422, `{"ok":false,"error":"teardown_failed","detail":"caddy validate rejected the disarm"}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code == exitOK {
		t.Fatalf("a refused teardown must not exit 0:\n%s", stdout)
	}
	if strings.Contains(stdout, "deleted") {
		t.Fatalf("a refused teardown must NOT print a deleted receipt:\n%s", stdout)
	}
}

// The alias `rm` reaches the same verb.
func TestRunCloudSiteDeleteRmAlias(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{200, deleteEnvelope}
	cp.serve()
	_, _, code := runSite(t, "table", "rm", testSiteID, "--yes")
	if code != exitOK {
		t.Fatalf("`rm` alias must reach delete, got exit=%d", code)
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

// TestRunCloudSiteStatusShowsStageDetail proves the status table is as honest as the
// live stream: the per-stage detail is on the stage bar, and a failed deployment's
// reason is in the header — so a user who missed the stream can still see WHY.
//
// deploy-reliability W2 — THE FIXTURE MOVED, THE RENDERER DID NOT. This test used
// to hand-feed `"current_deployment":{"status":"failed"}`, a payload the control
// plane can NEVER emit: the current pointer has three writers and all three are
// gated on status "live", and "live" is terminal in the transition table. So the
// header's failure arm was exercised only by a shape reality does not produce. The
// failed row now sits where a real one sits — the newest row of the deployments
// LIST — and the live pointer keeps the stage bar it really carries. Same
// renderers, reachable input.
func TestRunCloudSiteStatusShowsStageDetail(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[` +
		`{"name":"BUILD","status":"done","detail":"astro build in 1.7s"},` +
		`{"name":"HEALTH","status":"done","detail":"probe got 200 on /"}]}}}`}
	// The newest row: a LATER deploy that died at HEALTH. The list serializer emits
	// no stages and no url — only the base deployment fields — so this fixture
	// carries exactly what the route really returns.
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-2","site_id":"` + testSiteID + `","status":"failed","stage":"HEALTH",` +
		`"failure_reason":"probe got 500 on / (marker bp-build-id absent)",` +
		`"failure_reason_raw":"health probe: 500 on / after 30s","failure_class":"HEALTH_GATE_FAILED",` +
		`"environment":"production","inserted_at":"2026-08-06T01:00:00Z"}],"next_cursor":null}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "astro build in 1.7s") {
		t.Fatalf("status stage bar must carry the per-stage detail:\n%s", stdout)
	}
	// The header owes the reader the reason for a deployment that never went live.
	if !strings.Contains(stdout, "reason") || !strings.Contains(stdout, "probe got 500 on /") {
		t.Fatalf("status header must show the failure reason:\n%s", stdout)
	}
}

// TestRunCloudSiteStatusFlagsFailedNewestDeployment is the lie this slice kills, in
// the ONLY shape the control plane can actually produce: the site row's live
// pointer is a serene `live` deployment, and the newest ledger row — the thing that
// happened LAST — is a failure. Before the second read, `status` printed a bare
// "live" and nothing else; a person checking on a site whose every deploy had been
// failing for days saw a green word.
func TestRunCloudSiteStatusFlagsFailedNewestDeployment(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"failed","stage":"BUILD",` +
		`"failure_reason":"the build command exited non-zero — nothing was switched","failure_reason_raw":"BUILD failed (exit 1): npm ERR! code ELIFECYCLE",` +
		`"failure_class":"BUILD_FAILED","environment":"production"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	// The bound really went on the wire — one row is all this read needs.
	if cp.listHits != 1 {
		t.Fatalf("status must read the deployments list exactly once, got %d hits", cp.listHits)
	}
	if !strings.Contains(cp.listQuery, "limit=1") {
		t.Fatalf("status must bound the newest-deployment read, query=%q", cp.listQuery)
	}
	// The header no longer says a bare "live" and nothing else.
	for _, want := range []string{"NEWEST deploy FAILED", "dep-9", "BUILD_FAILED", "the build command exited non-zero"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("status header must carry %q over a failed newest deployment:\n%s", want, stdout)
		}
	}
	// The live pointer is still named — the older build IS what visitors see.
	if !strings.Contains(stdout, "dep-1") {
		t.Fatalf("status must still name the live deployment:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Deployment struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"deployment"`
		Latest struct {
			ID               string `json:"id"`
			Status           string `json:"status"`
			FailureClass     string `json:"failure_class"`
			FailureReasonRaw string `json:"failure_reason_raw"`
		} `json:"latest_deployment"`
		Staleness struct {
			LiveIsLatest       bool   `json:"live_is_latest"`
			LatestFailed       bool   `json:"latest_failed"`
			LiveDeploymentID   string `json:"live_deployment_id"`
			LatestDeploymentID string `json:"latest_deployment_id"`
			FailureClass       string `json:"failure_class"`
		} `json:"staleness"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	// `deployment` keeps its meaning — the LIVE pointer — so no existing reader moves.
	if env.Deployment.ID != "dep-1" || env.Deployment.Status != "live" {
		t.Fatalf("`deployment` must stay the live-pointer contract: %+v\n%s", env.Deployment, jstdout)
	}
	if env.Latest.ID != "dep-9" || env.Latest.Status != "failed" {
		t.Fatalf("`latest_deployment` must carry the newest row: %+v\n%s", env.Latest, jstdout)
	}
	if env.Latest.FailureClass != "BUILD_FAILED" || env.Latest.FailureReasonRaw != "BUILD failed (exit 1): npm ERR! code ELIFECYCLE" {
		t.Fatalf("the wide decode dropped the ledger's failure pair: %+v\n%s", env.Latest, jstdout)
	}
	if env.Staleness.LiveIsLatest || !env.Staleness.LatestFailed {
		t.Fatalf("staleness must say the live build is NOT the newest and the newest failed: %+v\n%s", env.Staleness, jstdout)
	}
	if env.Staleness.LiveDeploymentID != "dep-1" || env.Staleness.LatestDeploymentID != "dep-9" || env.Staleness.FailureClass != "BUILD_FAILED" {
		t.Fatalf("staleness node incomplete: %+v\n%s", env.Staleness, jstdout)
	}
}

// TestRunCloudSiteStatusLiveIsNewest is the other half of the same truth: when the
// live pointer IS the newest row, the header gains nothing and says "live" — the
// staleness machinery must not manufacture an alarm out of agreement.
func TestRunCloudSiteStatusLiveIsNewest(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-7","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-7","site_id":"` + testSiteID + `","status":"live","environment":"production"}],"next_cursor":null}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if strings.Contains(stdout, "FAILED") || strings.Contains(stdout, "newest deployment") {
		t.Fatalf("a site whose live build IS the newest must not be flagged stale:\n%s", stdout)
	}

	jstdout, _, _ := runSite(t, "json", "status", testSiteID)
	var env struct {
		Staleness struct {
			LiveIsLatest bool `json:"live_is_latest"`
			LatestFailed bool `json:"latest_failed"`
		} `json:"staleness"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if !env.Staleness.LiveIsLatest || env.Staleness.LatestFailed {
		t.Fatalf("staleness must report agreement: %+v\n%s", env.Staleness, jstdout)
	}
}

// TestRunCloudSiteStatusNewestReadFails proves the degradation is HONEST rather
// than silent: a control plane that will not answer the list leaves the live
// pointer true, so the verb still exits 0 and prints the header — but it says out
// loud that the staleness check did not run, and it emits NO staleness node
// (absent means unknown, never "in sync").
func TestRunCloudSiteStatusNewestReadFails(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{500, `{"error":"boom"}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("a failed secondary read must not fail the verb, exit=%d", code)
	}
	if !strings.Contains(stderr, "newest deployment") {
		t.Fatalf("the unread staleness check must be stated, not hidden:\n%s", stderr)
	}
	if !strings.Contains(stdout, "live") {
		t.Fatalf("the live pointer is still true and must still print:\n%s", stdout)
	}

	jstdout, _, _ := runSite(t, "json", "status", testSiteID)
	if strings.Contains(jstdout, "staleness") {
		t.Fatalf("an unread comparison must emit no staleness node:\n%s", jstdout)
	}
}

// TestRunCloudSiteStatusNeverLive covers the twin lie: a site with no live pointer
// at all whose only deploy failed. "no deployment yet — kick the first build" is
// wrong there; the build was kicked, and it died.
func TestRunCloudSiteStatusNeverLive(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-1","site_id":"` + testSiteID + `","status":"failed","stage":"BUILD",` +
		`"failure_reason":"the build command exited non-zero — nothing was switched","failure_class":"BUILD_FAILED"}],"next_cursor":null}`}
	cp.serve()
	stdout, _, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0", code)
	}
	if strings.Contains(stdout, "no deployment yet") {
		t.Fatalf("a site whose deploy FAILED has not 'no deployment yet':\n%s", stdout)
	}
	for _, want := range []string{"never went live", "BUILD_FAILED", "the build command exited non-zero"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("status must say %q:\n%s", want, stdout)
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
		{"create", "--name", "x", "--dataset", "a/b/c", "--instance", testInstanceID},
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
	// The prebuilt lane is advertised BY VALUE: there is no manifest and no
	// completion to find it in (bp capabilities describes an instance's content
	// API, not the control plane), so this help text IS the discoverability
	// surface — delete the line and this assertion is what reds.
	if !strings.Contains(stdout, "--prebuilt") {
		t.Fatalf("help must advertise --prebuilt — it is the only place a stranger can find the lane:\n%s", stdout)
	}
	if !strings.Contains(stdout, "runs NO npm") {
		t.Fatalf("help must say what --prebuilt buys (the box runs no npm):\n%s", stdout)
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

// The global -d/--dataset stripper consumes the flag wherever it appears in
// argv, so the create verb must honor the global capture — end-to-end through
// parseGlobals, not a direct-call unit test (the class of green that hid this).
func TestCloudSiteCreateDatasetSurvivesGlobalStripper(t *testing.T) {
	g, rest, err := parseGlobals([]string{
		"cloud", "site", "create",
		"--name", "x", "--dataset", "ws1/proj1/ds1", "--instance", "gone",
	})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	// The stripper eats --dataset (this is the collision under test) …
	for _, tok := range rest {
		if tok == "--dataset" || tok == "ws1/proj1/ds1" {
			t.Fatalf("expected the global stripper to consume --dataset; rest = %v", rest)
		}
	}
	// … and the verb-side fallback must see it via g.dataset.
	if g.dataset != "ws1/proj1/ds1" {
		t.Fatalf("g.dataset = %q, want the captured triple", g.dataset)
	}
	ws, proj, ds, derr := parseDatasetTriple(g.dataset)
	if derr != nil || ws != "ws1" || proj != "proj1" || ds != "ds1" {
		t.Fatalf("triple from global capture = %q %q %q (%v)", ws, proj, ds, derr)
	}
}

// --- W8: the receipts stop resting on a 2xx ----------------------------------
//
// Three lines claimed post-conditions nothing in the CLI (or in the envelope) had
// read. Each test below is the tripwire on ONE of them, end-to-end through the
// verb — the extracted renders are separately property-gated in
// success_claim_registry_test.go, and these pin the WORDING the user reads.

// TestSiteDeleteReceiptDoesNotAssertTheTeardown. Before:
//
//	✓ site deleted — blog is torn down on its box and deregistered.
//
// The box teardown is nowhere in the envelope ({"ok","status","slug"}), and the
// box's own teardown report is unconditional, so the "torn down" half was a claim
// about state nothing read.
func TestSiteDeleteReceiptDoesNotAssertTheTeardown(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{200, deleteEnvelope}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if strings.Contains(stdout, "torn down") {
		t.Fatalf("the delete receipt must not assert a teardown it never read:\n%s", stdout)
	}
	if !strings.Contains(stdout, "deregistered") || !strings.Contains(stdout, "blog") {
		t.Fatalf("the delete receipt must still claim what the envelope DOES back:\n%s", stdout)
	}
	if !strings.Contains(stdout, "UNVERIFIED") {
		t.Fatalf("the unread half must be named in the same breath:\n%s", stdout)
	}
}

// TestSiteDeleteReceiptRefusesANonDeletedEnvelope: a 200 is not the
// post-condition. An envelope that is not the deleted receipt gets no checkmark.
func TestSiteDeleteReceiptRefusesANonDeletedEnvelope(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{200, `{"ok":false,"status":"pending","slug":"blog"}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if strings.Contains(stdout, "✓") {
		t.Fatalf("a non-deleted envelope must not print a checkmark:\n%s", stdout)
	}
	if !strings.Contains(stdout, "UNCONFIRMED") {
		t.Fatalf("a non-deleted envelope must say so:\n%s", stdout)
	}
}

// TestSiteLiveReceiptSaysTheURLWasNotFetched. Before:
//
//	✓ site live — https://acme.barkpark.cloud/sites/blog/
//
// Nothing ever requested that URL; "live" is the control plane's record of its own
// SWITCH. The receipt now says which of the two it is.
func TestSiteLiveReceiptSaysTheURLWasNotFetched(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","stages":[]}}`}
	cp.pollResp = fakeResp{200, sixStagesLive}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "site live") || !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("the live receipt must still hand over the URL:\n%s", stdout)
	}
	if !strings.Contains(stdout, "did not fetch") {
		t.Fatalf("the live receipt must state that nothing fetched the URL:\n%s", stdout)
	}
	if !strings.Contains(stdout, "dep-1") {
		t.Fatalf("the live receipt must name the deployment record it read:\n%s", stdout)
	}
}

// TestSiteCreateWillNotClaimAnUnechoedDocTypeBinding. Before:
//
//	content: paper docs
//
// — a straight echo of the request flag, printed whether or not the control plane
// stored the binding, and phrased as if the dataset were known to serve that type.
func TestSiteCreateWillNotClaimAnUnechoedDocTypeBinding(t *testing.T) {
	cp := newSiteCP(t)
	// The CP stored the site but echoed NO doc_type (a pre-W10 control plane).
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog",
		"--dataset", "acme/blog/production", "--instance", testInstanceID, "--doc-type", "paper")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if strings.Contains(stdout, "content: paper docs") {
		t.Fatalf("an un-echoed doc type must not read as a stored binding:\n%s", stdout)
	}
	if !strings.Contains(stdout, "UNCONFIRMED") {
		t.Fatalf("an un-echoed doc type must say the binding is unconfirmed:\n%s", stdout)
	}
}

// TestSiteCreateNamesAnEchoedDocTypeBinding is the other half: when the control
// plane DID store the binding the receipt says so — and still refuses to claim the
// dataset serves that type, which nothing in THIS envelope has read. (The control
// plane does read it, at create, per charter D73 — but that verdict rides a
// top-level content_binding key SpawnSite does not carry, so this receipt names
// the check without narrating a result it was never shown.)
func TestSiteCreateNamesAnEchoedDocTypeBinding(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","doc_type":"paper"}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog",
		"--dataset", "acme/blog/production", "--instance", testInstanceID, "--doc-type", "paper")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "stored on the site row") {
		t.Fatalf("an echoed doc type must be reported as the stored binding:\n%s", stdout)
	}
	if strings.Contains(stdout, "UNCONFIRMED") {
		t.Fatalf("an echoed doc type is not unconfirmed:\n%s", stdout)
	}
	// The receipt must not narrate the create-time binding check's RESULT: this
	// envelope does not carry it. Naming that the check happens is honest; saying
	// how it came out would be quoting a read this process never made.
	if !strings.Contains(stdout, "not in this envelope") {
		t.Fatalf("the receipt must name the verdict it is not being shown:\n%s", stdout)
	}
	for _, verdict := range []string{"bound:", "unverified", "content_binding_empty"} {
		if strings.Contains(stdout, verdict) {
			t.Fatalf("the receipt must not report a binding verdict it never received (%q):\n%s", verdict, stdout)
		}
	}
}

// TestSiteCreateLabelsAnUnechoedDatasetBinding: siteDatasetLabel falls back to what
// the user typed, so a control plane that echoed nothing looked identical to one
// that confirmed the binding. The fallback is now labelled as the request.
func TestSiteCreateLabelsAnUnechoedDatasetBinding(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro"}}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "create", "--name", "blog",
		"--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "acme/blog/production") {
		t.Fatalf("the dataset line must still show the triple:\n%s", stdout)
	}
	if !strings.Contains(stdout, "as requested") {
		t.Fatalf("an un-echoed dataset must be labelled as the request:\n%s", stdout)
	}
}

// --- the prebuilt lane (charter D85/D87/D93/D94) ------------------------------

// writeDistFixture is a minimal build OUTPUT dir: a root index.html carrying the
// bp-build-id marker HEALTH asserts by value, one asset, and a .env that must
// never leave the machine.
func writeDistFixture(t *testing.T, buildID string) string {
	t.Helper()
	dir := t.TempDir()
	html := `<html><head><meta name="bp-build-id" content="` + buildID + `"></head><body>hi</body></html>`
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(html), 0o644); err != nil {
		t.Fatalf("write index.html: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "_astro"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "_astro", "app.css"), []byte("body{}"), 0o644); err != nil {
		t.Fatalf("write asset: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, ".env"), []byte("SECRET=hunter2\n"), 0o600); err != nil {
		t.Fatalf("write .env: %v", err)
	}
	return dir
}

// TestCloudSitePrebuiltDeployMintsThenUploadsSizedBytes is the wire proof of the
// two-call flow: /deploy carries source=prebuilt, and the artifact goes to the
// DEPLOYMENT-scoped route with a REAL Content-Length (not the chunked -1 a piped
// upload sends, which is why the client buffers) and the sha256 taken over
// exactly those wire bytes. The archive itself is decoded so "it uploaded
// something" can never pass for "it uploaded the build".
func TestCloudSitePrebuiltDeployMintsThenUploadsSizedBytes(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"artifact_url":"db://artifact/dep-1","filename":"dep-1.tar.gz"}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","stage":"RETIRE","build_id":"` + buildID + `","source":"prebuilt","url":"https://box.example/sites/blog/","stages":[{"name":"BUILD","status":"skipped","detail":"prebuilt bytes — no build ran on this box"},{"name":"SWITCH","status":"ok"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 1 {
		t.Fatalf("deploy hits=%d want 1 (the mint)", cp.deployHits)
	}
	var mint map[string]any
	if err := json.Unmarshal(cp.deployBody, &mint); err != nil {
		t.Fatalf("decode mint body %q: %v", cp.deployBody, err)
	}
	if mint["source"] != "prebuilt" {
		t.Fatalf("the mint must declare source=prebuilt, got %v", mint)
	}
	if cp.artifactHits != 1 {
		t.Fatalf("artifact hits=%d want 1", cp.artifactHits)
	}
	if cp.artifactPath != "/v1/sites/"+testSiteID+"/deployments/dep-1/artifact" {
		t.Fatalf("artifact went to %q — it must be scoped to the minted deployment", cp.artifactPath)
	}

	// The size is declared BEFORE the bytes move: a chunked body (-1) is exactly
	// what the buffer-to-temp-file design exists to avoid.
	if cp.artifactChunks {
		t.Fatalf("artifact was sent chunked (%v) — the server cannot reject it early", cp.artifactChunks)
	}
	if cp.artifactLen <= 0 {
		t.Fatalf("Content-Length=%d — the upload must declare a real length", cp.artifactLen)
	}
	if int(cp.artifactLen) != len(cp.artifactBody) {
		t.Fatalf("Content-Length=%d but %d bytes arrived", cp.artifactLen, len(cp.artifactBody))
	}

	// The digest is over the WIRE bytes, and it is on the request that carries them.
	sum := sha256.Sum256(cp.artifactBody)
	if want := hex.EncodeToString(sum[:]); cp.artifactSha != want {
		t.Fatalf("X-Artifact-Sha256=%q, but the received bytes hash to %q", cp.artifactSha, want)
	}

	// And the bytes are the BUILD: index.html at the archive root, the asset with
	// it, and no .env.
	names := tarEntryNames(t, bytes.NewReader(cp.artifactBody))
	for _, want := range []string{"index.html", "_astro/app.css"} {
		if _, ok := names[want]; !ok {
			t.Fatalf("uploaded archive is missing %s (a hollow shell would still upload and deploy)", want)
		}
	}
	if _, ok := names[".env"]; ok {
		t.Fatalf(".env was uploaded — the prebuilt ignore list must keep secrets off the wire")
	}

	if !strings.Contains(stdout, "no build started on the box") {
		t.Fatalf("the receipt must say the mint started no build:\n%s", stdout)
	}
	if !strings.Contains(stdout, "sha256 "+cp.artifactSha) {
		t.Fatalf("the receipt must name the digest it sent:\n%s", stdout)
	}
}

// TestCloudSitePrebuiltRefusesBytesWithTheWrongBuildID: HEALTH asserts the
// bp-build-id marker BY VALUE, so bytes stamped with anything else are a deploy
// that fails one round trip later. The CLI refuses BEFORE the upload and prints
// the exports the rebuild needs — the honest state, not a hopeful one.
func TestCloudSitePrebuiltRefusesBytesWithTheWrongBuildID(t *testing.T) {
	dir := writeDistFixture(t, "STALE-BUILD-ID")

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"freshbuildid00","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code == exitOK {
		t.Fatalf("a build-id mismatch must not exit 0\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	if cp.artifactHits != 0 {
		t.Fatalf("artifact hits=%d — nothing may be uploaded after a marker mismatch", cp.artifactHits)
	}
	all := stdout + stderr
	for _, want := range []string{"STALE-BUILD-ID", "freshbuildid00", "BARKPARK_BUILD_ID=freshbuildid00", "BARKPARK_CONTENT_REV=cr-42"} {
		if !strings.Contains(all, want) {
			t.Fatalf("the refusal must carry %q:\n%s", want, all)
		}
	}
	// THE LOOP MUST TERMINATE. A prebuilt mint is nonced on the control plane, so
	// "re-run the same command" would mint a DIFFERENT build id and refuse again,
	// forever. The refusal has to hand back the deployment the user just built
	// against.
	if !strings.Contains(all, "--deployment dep-1") {
		t.Fatalf("the refusal must name the deployment to ship to, or the retry loop never converges:\n%s", all)
	}
	if strings.Contains(all, "run this same command again") {
		t.Fatalf("the refusal must not promise a plain re-run reuses the deployment — a prebuilt mint is nonced:\n%s", all)
	}
}

// TestCloudSitePrebuiltResumesAnAlreadyMintedDeployment is the second half of
// the loop the refusal above starts: with --deployment the CLI mints NOTHING,
// reads the named row, and uploads against the build id already baked into the
// bytes. Without this the lane cannot succeed at all — the nonced mint would
// hand out a new build id on every run.
func TestCloudSitePrebuiltResumesAnAlreadyMintedDeployment(t *testing.T) {
	const buildID = "mintedbuild00001"
	dir := writeDistFixture(t, buildID)

	cp := newSiteCP(t)
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.artifactResp = fakeResp{201, `{"artifact_sha256":"x","bytes":1}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--deployment", "dep-1", "--no-follow")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if cp.deployHits != 0 {
		t.Fatalf("deploy hits=%d — --deployment must mint NOTHING", cp.deployHits)
	}
	if cp.artifactHits != 1 {
		t.Fatalf("artifact hits=%d want 1", cp.artifactHits)
	}
	if cp.artifactPath != "/v1/sites/"+testSiteID+"/deployments/dep-1/artifact" {
		t.Fatalf("artifact went to %q", cp.artifactPath)
	}
	if !strings.Contains(stdout, "already-minted deployment dep-1") {
		t.Fatalf("the receipt must say it reused the deployment:\n%s", stdout)
	}
}

// TestCloudSitePrebuiltRefusesAResumeThatCannotAcceptBytes: a deployment that has
// left `queued`, or that was never prebuilt, can never read an artifact. Say so
// before packing rather than after a 409.
func TestCloudSitePrebuiltRefusesAResumeThatCannotAcceptBytes(t *testing.T) {
	dir := writeDistFixture(t, "b1")

	cp := newSiteCP(t)
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"live","build_id":"b1","source":"prebuilt"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--deployment", "dep-1")
	if code == exitOK {
		t.Fatalf("a non-queued deployment must not exit 0\n%s%s", stdout, stderr)
	}
	if cp.artifactHits != 0 {
		t.Fatalf("nothing may be uploaded to a settled deployment (hits=%d)", cp.artifactHits)
	}
	if !strings.Contains(stdout+stderr, "already live") {
		t.Fatalf("the refusal must name the state that blocks it:\n%s%s", stdout, stderr)
	}

	cp2 := newSiteCP(t)
	cp2.pollResp = fakeResp{200, `{"deployment":{"id":"dep-2","status":"queued","build_id":"b1","source":"box-build"}}`}
	cp2.serve()

	stdout, stderr, code = runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--deployment", "dep-2")
	if code == exitOK {
		t.Fatalf("a box-build deployment must not accept an artifact\n%s%s", stdout, stderr)
	}
	if cp2.artifactHits != 0 {
		t.Fatalf("nothing may be uploaded to a box-build deployment (hits=%d)", cp2.artifactHits)
	}
}

// TestRunCloudSiteSettingsPrebuiltEnabled: the control plane refuses
// {"source":"prebuilt"} until the SITE opts in, so without this flag the whole
// lane is unreachable from bp — the 422 would have no answer in the CLI. Both
// polarities PATCH a real boolean (not the string the flag arrives as).
func TestRunCloudSiteSettingsPrebuiltEnabled(t *testing.T) {
	const siteJSON = `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","prebuilt_enabled":true}}`

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, siteJSON}
	cp.patchResp = fakeResp{200, siteJSON}
	cp.serve()

	_, stderr, code := runSite(t, "table", "settings", testSiteID, "--prebuilt-enabled", "true")
	if code != exitOK {
		t.Fatalf("settings exit=%d want 0\n%s", code, stderr)
	}
	if !bytes.Contains(cp.patchBody, []byte(`"prebuilt_enabled":true`)) {
		t.Fatalf("settings must PATCH a boolean prebuilt_enabled: %s", cp.patchBody)
	}

	cp2 := newSiteCP(t)
	cp2.getResp = fakeResp{200, siteJSON}
	cp2.patchResp = fakeResp{200, siteJSON}
	cp2.serve()
	if _, _, code = runSite(t, "table", "settings", testSiteID, "--prebuilt-enabled", "false"); code != exitOK {
		t.Fatalf("settings --prebuilt-enabled false exit=%d want 0", code)
	}
	if !bytes.Contains(cp2.patchBody, []byte(`"prebuilt_enabled":false`)) {
		t.Fatalf("settings must PATCH false, not omit it: %s", cp2.patchBody)
	}

	cp3 := newSiteCP(t)
	cp3.serve()
	stdout, stderr, code := runSite(t, "table", "settings", testSiteID, "--prebuilt-enabled", "maybe")
	if code != exitUsage {
		t.Fatalf("a non-boolean must be a usage error, got exit=%d\n%s%s", code, stdout, stderr)
	}
}

// TestCloudSiteDeploymentFlagNeedsPrebuilt: --deployment alone is a usage error,
// not a silently ignored flag.
func TestCloudSiteDeploymentFlagNeedsPrebuilt(t *testing.T) {
	cp := newSiteCP(t)
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--deployment", "dep-1")
	if code != exitUsage {
		t.Fatalf("exit=%d want %d\n%s%s", code, exitUsage, stdout, stderr)
	}
	if cp.deployHits != 0 {
		t.Fatalf("a usage error must touch no route (hits=%d)", cp.deployHits)
	}
}

// TestCloudSitePrebuiltRefusesABadDirBeforeAnyCall: an empty dir and a project
// dir are refused with NO network call at all — a mistyped path must never mint
// a deployment row.
func TestCloudSitePrebuiltRefusesABadDirBeforeAnyCall(t *testing.T) {
	cp := newSiteCP(t)
	cp.serve()

	empty := t.TempDir()
	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", empty)
	if code != exitUsage {
		t.Fatalf("empty dir exit=%d want %d\n%s%s", code, exitUsage, stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "is empty") {
		t.Fatalf("the refusal must say the dir is empty:\n%s%s", stdout, stderr)
	}

	project := t.TempDir()
	if err := os.WriteFile(filepath.Join(project, "package.json"), []byte("{}"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	stdout, stderr, code = runSite(t, "table", "deploy", testSiteID, "--prebuilt", project)
	if code != exitUsage {
		t.Fatalf("project dir exit=%d want %d\n%s%s", code, exitUsage, stdout, stderr)
	}
	if !strings.Contains(stdout+stderr, "no index.html") {
		t.Fatalf("the refusal must name the missing root index.html:\n%s%s", stdout, stderr)
	}

	if cp.deployHits != 0 || cp.artifactHits != 0 {
		t.Fatalf("a bad --prebuilt dir must touch no route (deploy=%d artifact=%d)", cp.deployHits, cp.artifactHits)
	}
}

// TestCloudSitePrebuiltPrintsThePathSiteBaseFromTheSlug is the fix for a printed
// export that was BOTH dead and wrong (site-spawner wave 10).
//
// DEAD: it was guarded on the deployment's URL, and the control plane's
// deployment_url returns nil for anything not live. A prebuilt mint is
// deliberately QUEUED, so that URL is always empty at mint time and the line
// could never print — while the help promises all three exports. The live walk
// (D103) saw exactly two.
//
// WRONG IF IT HAD FIRED: the URL is an absolute https URL, and
// templates/astro-starter/astro.config.mjs prefixes a leading slash to anything
// not already leading-slashed — so the built page would carry
// base="/https://host/sites/slug/" and EVERY asset href would 404. HEALTH cannot
// catch it: it asserts bp-build-id, bp-content-rev and bp-doc-id, never
// bp-site-base.
//
// So the export is now printed UNCONDITIONALLY, as the `/sites/<slug>/` PATH the
// deploy engine itself exports (deploy/site-deploy.sh: BARKPARK_SITE_BASE=
// "/sites/$SITE_SLUG/"), derived from the site's slug.
func TestCloudSitePrebuiltPrintsThePathSiteBaseFromTheSlug(t *testing.T) {
	dir := writeDistFixture(t, "STALE-BUILD-ID")

	cp := newSiteCP(t)
	// The mint's real shape: queued, and NO url — deployment_url is nil until live.
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"freshbuildid00","content_rev":"cr-42","source":"prebuilt"}}`}
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"Blog","slug":"blog","kind":"static"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	if code == exitOK {
		t.Fatalf("a marker mismatch must not exit 0\n%s%s", stdout, stderr)
	}
	all := stdout + stderr

	// The mint envelope carried no url at all — that is the state in which the old
	// guard silently dropped the line.
	var mint map[string]any
	if err := json.Unmarshal([]byte(cp.deployResp.body), &mint); err != nil {
		t.Fatalf("decode mint fixture: %v", err)
	}
	if dep, _ := mint["deployment"].(map[string]any); dep["url"] != nil {
		t.Fatalf("this test only proves anything while the mint carries no url: %v", dep)
	}

	// AFTER: the export prints anyway, and it is the PATH.
	const want = "export BARKPARK_SITE_BASE=/sites/blog/"
	if !strings.Contains(all, want) {
		t.Fatalf("the mint receipt must print %q — the help promises this export and a queued mint has no url to derive it from:\n%s", want, all)
	}
	// And it is NEVER the absolute URL form, which astro.config.mjs would turn into
	// base="/https://…" and kill every asset href on the page.
	if strings.Contains(all, "BARKPARK_SITE_BASE=http") {
		t.Fatalf("BARKPARK_SITE_BASE must be a path, never a full URL (astro prefixes a slash to it):\n%s", all)
	}

	// The help promises all three exports, so all three must print.
	for _, want := range []string{"BARKPARK_BUILD_ID=freshbuildid00", "BARKPARK_CONTENT_REV=cr-42", "BARKPARK_SITE_BASE=/sites/blog/"} {
		if !strings.Contains(all, want) {
			t.Fatalf("the receipt is missing the promised export %q:\n%s", want, all)
		}
	}
}

// TestCloudSitePrebuiltSiteBaseIgnoresADeploymentURL: even when a deployment DOES
// carry a url (a live row, or a control plane that starts emitting one at mint),
// the export stays the path. The URL is not a base and must never leak into one.
func TestCloudSitePrebuiltSiteBaseIgnoresADeploymentURL(t *testing.T) {
	dir := writeDistFixture(t, "STALE-BUILD-ID")

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-9","status":"queued","build_id":"freshbuildid00","content_rev":"cr-7","source":"prebuilt","url":"https://guerrilla.barkpark.cloud/sites/blog/"}}`}
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"Blog","slug":"blog"}}`}
	cp.serve()

	stdout, stderr, _ := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	all := stdout + stderr
	if !strings.Contains(all, "export BARKPARK_SITE_BASE=/sites/blog/") {
		t.Fatalf("the export must be the /sites/<slug>/ path:\n%s", all)
	}
	if strings.Contains(all, "BARKPARK_SITE_BASE=https://") {
		t.Fatalf("the deployment url leaked into the site base — that bakes base=\"/https://…\":\n%s", all)
	}
}

// TestCloudSitePrebuiltSiteBaseUnreadableRowWithAnIDRef: the slug is read from
// the site row, which is the authoritative source. When that read fails AND the
// caller addressed the site by its UUID, there is no slug anywhere in scope — so
// the line still prints (a missing export is how this bug shipped in the first
// place) but it prints a PLACEHOLDER plus a warning, never the id.
//
// Baking the id would produce `base="/sites/<uuid>/"`: a build whose every asset
// href 404s, and one the box cannot catch — HEALTH asserts bp-build-id,
// bp-content-rev and bp-doc-id by value and never looks at bp-site-base. A
// plausible wrong value is worse than an obvious placeholder.
func TestCloudSitePrebuiltSiteBaseUnreadableRowWithAnIDRef(t *testing.T) {
	dir := writeDistFixture(t, "STALE-BUILD-ID")

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","status":"queued","build_id":"freshbuildid00","source":"prebuilt"}}`}
	cp.getResp = fakeResp{500, `{"error":"boom"}`}
	cp.serve()

	stdout, stderr, _ := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
	all := stdout + stderr
	if !strings.Contains(all, "export BARKPARK_SITE_BASE=/sites/<slug>/") {
		t.Fatalf("an unreadable site row + an id ref must print the placeholder base:\n%s", all)
	}
	if strings.Contains(all, "BARKPARK_SITE_BASE=/sites/"+testSiteID+"/") {
		t.Fatalf("the site id was baked into the base — every asset href would 404:\n%s", all)
	}
	if !strings.Contains(all, "is an id rather than a slug") {
		t.Fatalf("the placeholder must say WHY it is a placeholder and what to substitute:\n%s", all)
	}
}

// TestSiteDeploymentDecodesPrebuiltFields: json.Unmarshal DROPS keys the struct
// does not model — the repo already learned this on Trigger — and content_rev is
// unrecoverable elsewhere (only the box computes it). This pins all three
// prebuilt fields by decoding a payload that carries them.
func TestSiteDeploymentDecodesPrebuiltFields(t *testing.T) {
	const payload = `{"id":"dep-1","status":"live","build_id":"b1","content_rev":"cr-42","source":"prebuilt","artifact_sha256":"deadbeef","trigger":"manual"}`
	var d cloudclient.SiteDeployment
	if err := json.Unmarshal([]byte(payload), &d); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if d.ContentRev != "cr-42" {
		t.Fatalf("content_rev dropped: %+v", d)
	}
	if d.Source != "prebuilt" {
		t.Fatalf("source dropped: %+v", d)
	}
	if d.SourceDigest != "deadbeef" {
		t.Fatalf("artifact_sha256 dropped: %+v", d)
	}
	if d.BuildID != "b1" || d.Trigger != "manual" {
		t.Fatalf("existing fields regressed: %+v", d)
	}
}

// TestRunCloudHelpListsSiteVerb: `bp cloud -h` did not mention the `site` verb AT
// ALL — eleven fleet verbs and `site` only as an ARGUMENT of `open` — so the only
// way to find the spawner was to already know it existed. `bp capabilities` can
// never fix this (it describes one instance's content API, not the control
// plane), so this seam is the discoverability path and this is its first test.
func TestRunCloudHelpListsSiteVerb(t *testing.T) {
	withTempConfigHome(t)
	g, rest, err := parseGlobals([]string{"cloud", "-h"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	if code := runCloud(w, g, rest[1:]); code != exitOK {
		t.Fatalf("bp cloud -h exit=%d want 0\n%s%s", code, sout.String(), serr.String())
	}
	out := sout.String()
	if !strings.Contains(out, "bp cloud site") {
		t.Fatalf("bp cloud -h must list the `site` verb:\n%s", out)
	}
	if !strings.Contains(out, "--prebuilt") {
		t.Fatalf("bp cloud -h must point at the prebuilt lane:\n%s", out)
	}
}
