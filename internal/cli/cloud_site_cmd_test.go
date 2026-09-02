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
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	// pollSeq, when non-empty, answers the n-th poll with its n-th entry (the
	// last entry repeats). pollResp models a stream that was ALREADY settled on
	// the first read; a real deploy usually walks queued → building → <terminal>,
	// and a test that only ever sees the terminal status on poll #1 cannot tell a
	// status-specific early exit from a working terminal predicate.
	pollSeq    []fakeResp
	getResp    fakeResp
	rollResp   fakeResp
	deleteResp fakeResp
	// GET /v1/sites/:id/deployments — the newest-first LIST `status` reads to
	// learn whether the live pointer is also the last thing that happened.
	// listQuery records the raw query so a test can prove the bound was sent.
	listResp  fakeResp
	listHits  int
	listQuery string
	// listSeq, when non-empty, answers the n-th LIST read with its n-th entry
	// (the last entry repeats) — the --wait-for-live loop reads the list
	// repeatedly, and its tests need the rebuild to appear live only on a later
	// read.
	listSeq []fakeResp
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

// pollAt is the response for the n-th (1-based) poll: pollSeq when a test set
// one, otherwise the single pollResp every pre-existing test uses. Past the end
// of pollSeq the last entry repeats, so a sequence ending in a non-terminal
// status still exercises the full poll budget rather than falling off a cliff.
func (cp *siteCP) pollAt(n int) fakeResp {
	if len(cp.pollSeq) == 0 {
		return cp.pollResp
	}
	if n > len(cp.pollSeq) {
		return cp.pollSeq[len(cp.pollSeq)-1]
	}
	return cp.pollSeq[n-1]
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
			cp.write(w, cp.pollAt(cp.pollHits))
		// The LIST route (no trailing slash) — `bp cloud site status`'s second read.
		// The poll case above matches ".../deployments/" WITH the slash, so before
		// this case a bare list GET fell to the default arm and t.Fatal'd every
		// status test. Default body is an empty page, which is what a site with no
		// deployments returns and what every pre-existing test wants.
		case r.Method == "GET" && path == "/v1/sites/"+testSiteID+"/deployments":
			cp.listHits++
			cp.listQuery = r.URL.RawQuery
			if len(cp.listSeq) > 0 {
				n := cp.listHits
				if n > len(cp.listSeq) {
					n = len(cp.listSeq)
				}
				cp.write(w, cp.listSeq[n-1])
				break
			}
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

// --- the create-time content-binding verdict (ssw8) --------------------------
//
// POST /v1/sites answers 201 with the row under `site` AND the control plane's own
// create-time read of the bound type under a TOP-LEVEL `content_binding` key. The
// CLI decoded `{site}` alone, so the verdict was discarded before any render could
// see it: a create that came back UNVERIFIED printed the same confident line as one
// the control plane had actually read.
//
// The producer's shape, which these fixtures mirror EXACTLY (cloud router
// binding_note/1):
//
//	{"status":"bound","doc_type":"post","count":12}   bound, with the box's total
//	{"status":"bound","doc_type":"post"}              bound, box published NO total
//	{"status":"unverified","detail":"…"}              the key is `detail`, not `reason`
//	(no content_binding key at all)                   the kind was never probed
//
// siteCreated201 runs one create against a 201 whose body is the caller's, and
// returns the human receipt. The row is held IDENTICAL across every case here so
// the only thing that can move the printed bytes is the verdict.
func siteCreated201(t *testing.T, contentBinding string) (string, string, int) {
	t.Helper()
	cp := newSiteCP(t)
	body := `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro",` +
		`"workspace":"acme","project":"blog","dataset":"production","doc_type":"post"}`
	if contentBinding != "" {
		body += `,"content_binding":` + contentBinding
	}
	cp.createResp = fakeResp{201, body + `}`}
	cp.serve()
	return runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID, "--doc-type", "post")
}

// UNVERIFIED is the case this whole change exists for: the control plane could NOT
// confirm the site can read its type, and the operator was told nothing.
func TestRunCloudSiteCreateSurfacesUnverifiedBinding(t *testing.T) {
	stdout, stderr, code := siteCreated201(t, `{"status":"unverified","detail":"blog-box has no URL yet — the site's content could not be read"}`)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The verdict must be NAMED as not-confirmed. Lowercase "not" would pass on a
	// sentence that says the opposite, so the shouted token is the assertion.
	if !strings.Contains(stdout, "NOT confirm") {
		t.Fatalf("an unverified create must say the binding could NOT be confirmed:\n%s", stdout)
	}
	// And the server's REASON must be relayed — the whole value of the key.
	if !strings.Contains(stdout, "blog-box has no URL yet") {
		t.Fatalf("an unverified create must relay the control plane's detail:\n%s", stdout)
	}
	// The stale claim the old line carried must be gone: this envelope DOES carry
	// the verdict now.
	if strings.Contains(stdout, "not in this envelope") {
		t.Fatalf("the receipt still says the verdict is not in the envelope — it is:\n%s", stdout)
	}
}

// BOUND WITH A COUNT: name the type and the magnitude the control plane read.
func TestRunCloudSiteCreateSurfacesBoundBindingWithCount(t *testing.T) {
	stdout, stderr, code := siteCreated201(t, `{"status":"bound","doc_type":"post","count":12}`)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "12") {
		t.Fatalf("a bound create with a count must print the count:\n%s", stdout)
	}
	if !strings.Contains(stdout, "post") {
		t.Fatalf("a bound create must name the doc type the control plane read:\n%s", stdout)
	}
	if strings.Contains(stdout, "NOT confirm") {
		t.Fatalf("a bound create must not narrate a failed verification:\n%s", stdout)
	}
}

// BOUND WITHOUT A COUNT: the producer OMITS `count` when the box published no
// total, so the receipt must say bound and invent NO number. The "0" assertion is
// the one that reds a `Count int` decode, where absent and zero are the same value.
func TestRunCloudSiteCreateBoundWithoutCountInventsNoNumber(t *testing.T) {
	stdout, stderr, code := siteCreated201(t, `{"status":"bound","doc_type":"post"}`)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if !strings.Contains(stdout, "no total") {
		t.Fatalf("a bound create with no count must say the box published no total:\n%s", stdout)
	}
	// No digit may appear on the content line at all — "0 documents" about a site
	// nobody counted is exactly the lie the pointer exists to prevent.
	for _, line := range strings.Split(stdout, "\n") {
		if !strings.Contains(line, "content:") {
			continue
		}
		if strings.ContainsAny(line, "0123456789") {
			t.Fatalf("a count-less bound verdict must carry NO number, got %q", line)
		}
	}
}

// NO content_binding KEY AT ALL (the control plane did not probe this kind): the
// receipt renders exactly as it did before this change — the stored-row line, no
// verdict sentence, and above all NOT an "unverified" one.
func TestRunCloudSiteCreateWithoutBindingKeyRendersNoVerdict(t *testing.T) {
	stdout, stderr, code := siteCreated201(t, "")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if strings.Contains(stdout, "NOT confirm") || strings.Contains(stdout, "unverified") {
		t.Fatalf("an absent content_binding is NO verdict, not a bad one:\n%s", stdout)
	}
	if strings.Contains(stdout, "read") && strings.Contains(stdout, "documents") {
		t.Fatalf("an absent content_binding must claim no read:\n%s", stdout)
	}
	if !strings.Contains(stdout, "content: post") {
		t.Fatalf("the stored-row content line must survive unchanged:\n%s", stdout)
	}
}

// The MACHINE surface carries the verdict too: a script branching on the create
// envelope gets the same fact the human line does.
func TestRunCloudSiteCreateJSONCarriesTheBindingVerdict(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{201, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static"},` +
		`"content_binding":{"status":"unverified","detail":"blog-box could not be reached"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stdout)
	}
	var env struct {
		ContentBinding struct {
			Status string `json:"status"`
			Detail string `json:"detail"`
		} `json:"content_binding"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json output not parseable: %v\n%s", err, stdout)
	}
	if env.ContentBinding.Status != "unverified" || env.ContentBinding.Detail != "blog-box could not be reached" {
		t.Fatalf("the machine envelope must carry the verdict, got %+v\n%s", env.ContentBinding, stdout)
	}
}

// ...and an envelope with NO verdict must carry no key, so a script can tell "not
// probed" from "unverified" without reading prose.
func TestRunCloudSiteCreateJSONOmitsAnAbsentBindingVerdict(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{201, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static"}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stdout)
	}
	if strings.Contains(stdout, "content_binding") {
		t.Fatalf("an absent verdict must not materialise as a key in the envelope:\n%s", stdout)
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

// TestRunCloudSiteDeployDeferredStopsPollingAndNamesTheRefusal is the wave-32 cure
// for the MAJORITY outcome (deploy-reliability charter D543). `deferred` is 73.7%
// of settled deploy attempts (D209) and was terminal server-side all along
// (registry/deployment.ex maps it to []), but it was missing from
// cloudclient.SiteDeploymentTerminal — so with follow ON BY DEFAULT this exact
// fixture used to burn all 300 polls (300 × 2s ≈ 10 min, one GET every 2s against
// the very box that had just said it was at capacity) and then print
// "… deploy in progress (stage BUILD)" over a row the control plane had already
// settled. The refusal reason was on the wire from the FIRST poll and never shown.
//
// Two things are pinned here and they fail for different reasons: the poll count
// (the ten minutes) and the sentence (the lie).
func TestRunCloudSiteDeployDeferredStopsPollingAndNamesTheRefusal(t *testing.T) {
	const deferredReason = "the instance refused the deploy (HTTP 409): box_at_capacity — the box is at its build capacity (1 of 1 build slots in use) — deferred: refusal 3 of 12 in this site's current chain — a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"

	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[{"name":"PLAN","status":"done"}]}}`}
	// The FIRST poll already settles deferred — nothing after it can ever change.
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","failure_reason":` + mustJSONString(deferredReason) + `,"failure_class":"BOX_AT_CAPACITY_DEFERRED","stages":[{"name":"PLAN","status":"done"}]}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	// THE TEN MINUTES. One poll, not siteDeployPollMax of them.
	if cp.pollHits != 1 {
		// siteDeployPoll is forced to 0 in tests, so the budget is quoted from the
		// PRODUCTION interval (2s) rather than the harness's.
		t.Fatalf("a deferred deploy polled %d times, want exactly 1 — deferred is terminal server-side, so anything above 1 is the CLI re-asking a row that can never change, and %d of them is the full siteDeployPollMax(%d)×2s ≈ 10 minute spin an operator sat through",
			cp.pollHits, siteDeployPollMax, siteDeployPollMax)
	}
	// THE LIE. "in progress" is the sentence this test exists to keep out.
	if strings.Contains(stdout, "in progress") {
		t.Fatalf("a settled deferred row must never be narrated as in progress:\n%s", stdout)
	}
	if strings.Contains(stdout, "site live") {
		t.Fatalf("a deferred deploy never went live:\n%s", stdout)
	}
	// THE TRUTH, all three parts: what happened, how deep the chain is (through
	// siteDeferralLine, so the depth arrives with its own honest gloss rather than
	// as a bare countdown), and that the rebuild is already queued — an operator
	// who re-publishes by hand here just deepens the chain.
	for _, want := range []string{
		"deferred",
		"the box refused this round",
		"visitors still see the previous build",
		"refusal 3 of 12 consecutive",
		"any successful deploy resets it to 0",
		"zero-progress guard, not a countdown",
		"already queued",
		"do NOT re-publish",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the deferred verdict must say %q:\n%s\nstderr:%s", want, stdout, stderr)
		}
	}
	// A deferral is not a drop, and the failure vocabulary must not leak onto it.
	if strings.Contains(stdout, "failed") || strings.Contains(stderr, "failed") {
		t.Fatalf("a deferral is a refusal, not a failure:\n%s\n%s", stdout, stderr)
	}
	if code != exitOK {
		t.Fatalf("exit=%d want 0 (charter D543)\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
}

// TestRunCloudSiteDeployDeferredMidStreamStopsAtTheDeferral covers the stream the
// fixture above cannot: a deploy that is genuinely in progress for two polls and
// THEN defers, which is the likelier live sequence (the box accepts the row, walks
// to BUILD, and only there discovers it is at capacity). The sibling test settles
// on poll #1, so it would still pass if the loop had grown a status-specific early
// exit rather than a working terminal predicate; this one pins that the loop keeps
// polling while the row can still change and stops the moment it cannot.
func TestRunCloudSiteDeployDeferredMidStreamStopsAtTheDeferral(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","stages":[]}}`}
	cp.pollSeq = []fakeResp{
		{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","stages":[{"name":"PLAN","status":"done"}]}}`},
		{200, `{"deployment":{"id":"dep-1","status":"building","stage":"BUILD","stages":[{"name":"PLAN","status":"done"},{"name":"BUILD","status":"running"}]}}`},
		{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","failure_class":"BOX_AT_CAPACITY_DEFERRED","failure_reason":"box_at_capacity — deferred: refusal 2 of 12 in this site's current chain — a rebuild carrying this content has been re-queued","stages":[{"name":"PLAN","status":"done"}]}}`},
	}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID)
	// Three polls: two that had to happen (the row could still change) and the
	// one that settled it. Anything more is the ten-minute spin re-asking a
	// settled row; anything less means the loop quit while the deploy was live.
	if cp.pollHits != 3 {
		t.Fatalf("polled %d times, want exactly 3 (queued, building, deferred)\nstdout:%s", cp.pollHits, stdout)
	}
	if strings.Contains(stdout, "in progress") {
		t.Fatalf("a settled deferred row must never be narrated as in progress:\n%s", stdout)
	}
	for _, want := range []string{"deferred", "the box refused this round", "already queued"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the deferred verdict must say %q:\n%s\nstderr:%s", want, stdout, stderr)
		}
	}
	if code != exitOK {
		t.Fatalf("exit=%d want 0 (charter D543)", code)
	}
}

// TestRunCloudSiteDeployWaitForLiveRidesPastTheDeferral is dr-w32-bl's proof:
// the deploy settles DEFERRED (the honest deferral narration prints, as
// always), and --wait-for-live then keeps polling the site's deployment LIST
// until a live row for the same site+environment appears — a row that PROVABLY
// postdates the deferral. The fixture's first list page carries the trap this
// wait must not fall into: the site's PREVIOUS build is already live (older
// inserted_at), and declaring victory on it would bless exactly the bytes the
// caller is waiting to replace. The second page carries a preview-environment
// live row (wrong environment, must be skipped) and the production rebuild.
func TestRunCloudSiteDeployWaitForLiveRidesPastTheDeferral(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","environment":"production","inserted_at":"2026-08-23T10:00:00Z",` +
		`"failure_class":"BOX_AT_CAPACITY_DEFERRED","failure_reason":"box_at_capacity — deferred: refusal 1 of 12 in this site's current chain — a rebuild carrying this content has been re-queued","stages":[]}}`}
	oldLive := `{"id":"dep-old","site_id":"` + testSiteID + `","status":"live","environment":"production","inserted_at":"2026-08-23T09:00:00Z","url":"https://old.example"}`
	rebuildQueued := `{"id":"dep-rebuild","site_id":"` + testSiteID + `","status":"queued","environment":"production","inserted_at":"2026-08-23T10:00:05Z"}`
	previewLive := `{"id":"dep-preview","site_id":"` + testSiteID + `","status":"live","environment":"preview","inserted_at":"2026-08-23T10:00:30Z","url":"https://preview.example"}`
	rebuildLive := `{"id":"dep-rebuild","site_id":"` + testSiteID + `","status":"live","environment":"production","inserted_at":"2026-08-23T10:00:05Z","url":"https://site.example"}`
	cp.listSeq = []fakeResp{
		{200, `{"deployments":[` + rebuildQueued + `,` + oldLive + `],"next_cursor":null}`},
		{200, `{"deployments":[` + rebuildLive + `,` + previewLive + `,` + oldLive + `],"next_cursor":null}`},
	}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--wait-for-live", "5m")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	// The deferral narration still printed in full — the wait rides PAST it,
	// never over it (the task's own wording).
	for _, want := range []string{"deferred", "the box refused this round", "already queued", "do NOT re-publish"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the deferral narration must still print %q under --wait-for-live:\n%s", want, stdout)
		}
	}
	// Victory is the REBUILD, proven by id — not the previous build, not the
	// preview-environment row.
	if !strings.Contains(stdout, "site live") || !strings.Contains(stdout, "dep-rebuild") {
		t.Fatalf("the wait must end on the rebuild going live:\n%s", stdout)
	}
	for _, forbidden := range []string{"dep-old", "dep-preview"} {
		if strings.Contains(stdout, forbidden) {
			t.Fatalf("the wait declared victory on %s — the wrong row:\n%s", forbidden, stdout)
		}
	}
	// Two list reads: one that found only the queued rebuild, one that found it
	// live. The wait stopped the moment it had its answer.
	if cp.listHits != 2 {
		t.Fatalf("list read %d times, want exactly 2\n%s", cp.listHits, stdout)
	}
}

// TestRunCloudSiteDeployWaitForLiveDeadlineExpiresNonZero: the wait's deadline
// is the CALLER'S, stated on the flag, and expiring it is a non-zero exit that
// names the deadline and the last status read — never a bare timeout, and never
// a claim that anything was lost (the rebuild stays queued).
func TestRunCloudSiteDeployWaitForLiveDeadlineExpiresNonZero(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","environment":"production","inserted_at":"2026-08-23T10:00:00Z",` +
		`"failure_reason":"box_at_capacity — deferred: refusal 1 of 12 in this site's current chain","stages":[]}}`}
	// The rebuild never goes live inside the window.
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-rebuild","site_id":"` + testSiteID + `","status":"queued","environment":"production","inserted_at":"2026-08-23T10:00:05Z"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "deploy", testSiteID, "--wait-for-live", "1ms")
	if code == exitOK {
		t.Fatalf("an expired --wait-for-live deadline must exit non-zero\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	for _, want := range []string{"deadline 1ms expired", "queued", "Nothing was lost"} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("the expiry must say %q (the deadline and the last status read, never a bare timeout):\nstderr:%s", want, stderr)
		}
	}
	if !strings.Contains(stdout, "deferred") {
		t.Fatalf("the deferral narration must still have printed:\n%s", stdout)
	}
}

// TestRunCloudSiteDeployWithoutWaitForLiveNeverReadsTheList pins criterion 2's
// mechanism: the default path does not merely keep exit 0 — it performs ZERO
// wait reads. Together with the unmodified D543 tests above (poll counts,
// sentences, exit codes), this is the default path staying byte-identical.
func TestRunCloudSiteDeployWithoutWaitForLiveNeverReadsTheList(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","failure_reason":"box_at_capacity — deferred: refusal 1 of 12 in this site's current chain","stages":[]}}`}
	cp.serve()

	_, _, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0 (charter D543)", code)
	}
	if cp.listHits != 0 {
		t.Fatalf("a deploy without --wait-for-live read the deployment list %d times — the default path must not change", cp.listHits)
	}
	if cp.pollHits != 1 {
		t.Fatalf("polled %d times, want exactly 1", cp.pollHits)
	}
}

// TestRunCloudSiteDeployWaitForLiveRefusals: the flag's own contract is refused
// locally, before any network — a junk deadline, a follow-less wait, and the
// machine outputs whose single-envelope stdout the wait cannot honour.
func TestRunCloudSiteDeployWaitForLiveRefusals(t *testing.T) {
	cases := []struct {
		name string
		args []string
		out  string
		want string
	}{
		{"junk deadline", []string{"deploy", testSiteID, "--wait-for-live", "soon"}, "table", "positive deadline"},
		{"no-follow", []string{"deploy", testSiteID, "--wait-for-live", "5m", "--no-follow"}, "table", "drop --no-follow"},
		{"json output", []string{"deploy", testSiteID, "--wait-for-live", "5m"}, "json", "exit code IS the machine answer"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cp := newSiteCP(t)
			cp.serve()
			stdout, stderr, code := runSite(t, tc.out, tc.args...)
			if code != exitUsage {
				t.Fatalf("exit=%d want %d (exitUsage)\nstderr:%s", code, exitUsage, stderr)
			}
			// -o json refusals land as the error envelope on stdout; human ones
			// on stderr. The sentence is what is pinned, wherever it went.
			if all := stdout + stderr; !strings.Contains(all, tc.want) {
				t.Fatalf("refusal must say %q:\n%s", tc.want, all)
			}
			if cp.deployHits != 0 {
				t.Fatalf("a refused invocation reached the deploy route %d times", cp.deployHits)
			}
		})
	}
}

// TestRenderSiteDeployVerdictDeferredWithNoStageDoesNotInventOne pins the one
// place this verdict could fabricate: an empty Stage. The first cut defaulted it
// to "PLAN" — the stage a deferral plausibly stops at, printed as though it had
// been read. A control plane that sends no stage must produce a sentence that
// says no stage was named.
func TestRenderSiteDeployVerdictDeferredWithNoStageDoesNotInventOne(t *testing.T) {
	out, buf, errBuf := newTestWriter()
	code := renderSiteDeployVerdict(out, testSiteID, cloudclient.SiteDeployment{
		ID: "dep-1", Status: "deferred",
		FailureReason: "box_at_capacity — deferred: refusal 1 of 12 in this site's current chain",
	})
	stdout := buf.String()
	if strings.Contains(stdout, "PLAN") || strings.Contains(stdout, "BUILD") {
		t.Fatalf("an absent stage must never be rendered as a named one:\n%s", stdout)
	}
	if !strings.Contains(stdout, "deferred before it named a stage") {
		t.Fatalf("the no-stage deferral must say so out loud:\n%s\nstderr:%s", stdout, errBuf.String())
	}
	if code != exitOK {
		t.Fatalf("exit=%d want 0 (charter D543)", code)
	}
}

// TestRunCloudSiteDeployDeferredKeepsExitZero pins charter D543 — the exit code is
// a DECISION, not an accident, and this test is what stops a future wave flipping
// it on the reasoning that "it didn't go live". It didn't, and it also lost
// nothing: wave 32 measured content coverage at 100.00% on settled deferrals
// because the re-queued rebuild carries the same content and lands. Since deferral
// is ~74% of deploy invocations, a non-zero exit here would break every
// `deploy && notify` chain and every `set -e` script for an outcome that costs a
// wait — cry-wolf on the operator surface, which is the failure this epic exists
// to prevent. Callers that genuinely need liveness get an opt-in --wait-for-live
// (dr-w32-bl-deploy-wait-for-live-flag), not a redefinition of this code.
func TestRunCloudSiteDeployDeferredKeepsExitZero(t *testing.T) {
	deferred := cloudclient.SiteDeployment{
		ID: "dep-1", Status: "deferred", Stage: "BUILD",
		FailureReason: "box_at_capacity — deferred: refusal 3 of 12 in this site's current chain — a rebuild carrying this content has been re-queued",
	}
	if got := siteDeployExit(deferred); got != exitOK {
		t.Fatalf("siteDeployExit(deferred) = %d, want %d — D543 decided deferred keeps exit 0; flipping it breaks every `deploy && notify` chain for ~74%% of invocations, and the honest fix is the SENTENCE, not the code", got, exitOK)
	}
	// The neighbours it must NOT be confused with: both are drops, both stay
	// non-zero, so the ruling above is narrow rather than a blanket exit 0.
	for _, drop := range []string{"failed", "cancelled"} {
		if got := siteDeployExit(cloudclient.SiteDeployment{ID: "dep-2", Status: drop}); got != exitGeneric {
			t.Fatalf("siteDeployExit(%q) = %d, want %d — a dropped deploy must never exit 0", drop, got, exitGeneric)
		}
	}

	// And the machine lane agrees end to end: -o json emits the envelope carrying
	// the deferred status and still exits 0, so a script reads the OUTCOME from the
	// payload rather than inferring a failure from $?.
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stages":[]}}`}
	cp.pollResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","stages":[]}}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "deploy", testSiteID)
	if code != exitOK {
		t.Fatalf("deferred -o json exit=%d want %d", code, exitOK)
	}
	if cp.pollHits != 1 {
		t.Fatalf("-o json polled %d times, want 1 — the machine lane must collapse too", cp.pollHits)
	}
	var env struct {
		Deployment struct {
			Status string `json:"status"`
		} `json:"deployment"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("deploy json not parseable: %v\n%s", err, stdout)
	}
	if env.Deployment.Status != "deferred" {
		t.Fatalf("the envelope must carry the deferred status (that is how a script learns the outcome it cannot read from $?): %+v\n%s", env.Deployment, stdout)
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

// --- typed site refusals (cch-w69 S6) ----------------------------------------
//
// RED BEFORE (recorded, and reproducible by reverting cloud_site_cmd.go alone):
// both verbs used to hand the refusal to the bare `cloudFail`, which branches on
// the substring "unauthorized" and nothing else. Every refusal below therefore
// printed the label "failed" and exited 1 — a 409 the box refused, a 404 that is
// not our site and a 500 the plane crashed on were one undifferentiated exit, and
// `-o json` carried "failed" instead of the plane's own code. The pre-fix exits
// were: identity_refused 409 → 1 (want 6), teardown_failed 422 → 1 (want 1, but
// labelled "failed" instead of "teardown_failed"), 502 → 1 (want 8), 404 → 1
// (want 4), forbidden 403 → 3 only by the "unauthorized" substring accident.

// siteIdentityRefusedDetail is the control plane's OWN sentence for the refused
// box (cloud/lib/barkpark_cloud/sites/deploy.ex `unreachable/2`
// :identity_refused). The CLI relays it rather than minting a third wording, so
// this fixture is the plane's bytes.
const siteIdentityRefusedDetail = "The request was never sent — the instance rejected our access credential. Barkpark Cloud stops asking a box that refused it; the hourly update check is what notices the credential working again."

func TestRunCloudSiteDeleteIdentityRefusedIsAConflict(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{409, `{"ok":false,"error":"identity_refused","detail":"` + siteIdentityRefusedDetail + `"}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitConflict {
		t.Fatalf("a 409 identity_refused must exit %d (conflict), got %d\n%s", exitConflict, code, stderr)
	}
	if strings.Contains(stdout, "deregistered") {
		t.Fatalf("a refused teardown must not print a delete receipt:\n%s", stdout)
	}
	// The plane's sentence is RELAYED, not forked.
	if !strings.Contains(stderr, "the instance rejected our access credential") {
		t.Fatalf("the refusal must relay the plane's detail:\n%s", stderr)
	}
	if !strings.Contains(stderr, "still registered") {
		t.Fatalf("a refused teardown must say the site is still registered:\n%s", stderr)
	}
}

func TestRunCloudSiteRollbackIdentityRefusedIsAConflict(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{409, `{"ok":false,"error":"identity_refused","detail":"` + siteIdentityRefusedDetail + `"}`}
	cp.serve()
	stdout, stderr, code := runSite(t, "table", "rollback", testSiteID)
	if code != exitConflict {
		t.Fatalf("a 409 identity_refused must exit %d (conflict), got %d\n%s", exitConflict, code, stderr)
	}
	if strings.Contains(stdout, "rolled back") {
		t.Fatalf("a refused rollback must not print a rollback receipt:\n%s", stdout)
	}
	if !strings.Contains(stderr, "the instance rejected our access credential") {
		t.Fatalf("the refusal must relay the plane's detail:\n%s", stderr)
	}
	if !strings.Contains(stderr, "Nothing was flipped") {
		t.Fatalf("a refused rollback must say nothing was flipped:\n%s", stderr)
	}
}

// A 422 teardown_failed keeps exit 1 (the ladder's default family) but must stop
// printing the label "failed": -o json has to name the plane's own code, or no
// script can tell a refused teardown from a transport error.
func TestRunCloudSiteDeleteTeardownFailedJSONCarriesThePlanesCode(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{422, `{"ok":false,"error":"teardown_failed","detail":"caddy validate rejected the disarm"}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "delete", testSiteID, "--yes")
	if code != exitGeneric {
		t.Fatalf("a 422 teardown_failed must exit %d, got %d", exitGeneric, code)
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json envelope: %v\n%s", err, stdout)
	}
	if env.OK {
		t.Fatalf("a refusal envelope must be ok:false:\n%s", stdout)
	}
	if env.Error.Code != "teardown_failed" {
		t.Fatalf("json must carry the plane's code, got %q\n%s", env.Error.Code, stdout)
	}
	if !strings.Contains(env.Error.Message, "caddy validate rejected the disarm") {
		t.Fatalf("the message must relay the plane's detail, got %q", env.Error.Message)
	}
}

// 5xx → exitServer: the plane itself failed, which is a different retry story
// from a refusal it measured.
func TestRunCloudSiteRollbackServerFailureExitsServer(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{502, `{"ok":false,"error":"rollback_failed","detail":"instance blog is unreachable — the rollback could not be delivered"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "rollback", testSiteID)
	if code != exitServer {
		t.Fatalf("a 502 must exit %d (server), got %d\n%s", exitServer, code, stderr)
	}
	// An unknown/flat code still relays the plane's sentence — the default arm.
	if !strings.Contains(stderr, "could not be delivered") {
		t.Fatalf("the default arm must relay the plane's detail:\n%s", stderr)
	}
}

func TestRunCloudSiteDeleteNotFoundExitsNotFound(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{404, `{"error":"not_found"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitNotFound {
		t.Fatalf("a 404 must exit %d (not-found), got %d\n%s", exitNotFound, code, stderr)
	}
	if !strings.Contains(stderr, "no such site") {
		t.Fatalf("a 404 must name the site as unknown:\n%s", stderr)
	}
}

// The CAUSE outranks the STATUS: a teamless login is exit 1 with `bp team use`,
// never exit 3 — the credential is fine (the doctrine #11711 pins).
func TestRunCloudSiteDeleteNoTeamStaysGenericWithTheTeamFix(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{403, `{"error":"forbidden","reason":"no_team"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitGeneric {
		t.Fatalf("a no_team refusal must stay exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stderr, "bp team use") {
		t.Fatalf("a no_team refusal must point at `bp team use`:\n%s", stderr)
	}
}

// A plain 403 (the write ability, not the team) is an auth exit.
func TestRunCloudSiteRollbackForbiddenExitsAuth(t *testing.T) {
	cp := newSiteCP(t)
	cp.rollResp = fakeResp{403, `{"error":"forbidden","required":"write","scope":"team"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "rollback", testSiteID)
	if code != exitAuth {
		t.Fatalf("a 403 forbidden must exit %d (auth), got %d\n%s", exitAuth, code, stderr)
	}
	if !strings.Contains(stderr, "write") {
		t.Fatalf("a forbidden refusal must name the ability it wanted:\n%s", stderr)
	}
}

// THE PRESERVED SEAM: a refusal that is NOT a typed CloudRefusal (or a 401 whose
// message carries the "unauthorized:" prefix) must still route through cloudFail
// so expired-session handling reads identically to every other cloud verb.
func TestRunCloudSiteDeleteUnauthorizedKeepsTheCloudFailSeam(t *testing.T) {
	cp := newSiteCP(t)
	cp.deleteResp = fakeResp{401, `{"error":"invalid_token"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "delete", testSiteID, "--yes")
	if code != exitAuth {
		t.Fatalf("a 401 must exit %d (auth), got %d\n%s", exitAuth, code, stderr)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("the 401 seam must still tell the user to re-run `bp login`:\n%s", stderr)
	}
}

// --- typed create refusals (cch-w70 round 1, D862) ---------------------------
//
// bp cloud site create now joins the ONE #11784 refusal dialect (siteRefusedCreate)
// instead of the bare cloudFail(out, "create site", cerr) it used to hand every
// refusal to. That old seam branched only on the substring "unauthorized": a
// user-fixable 422, a transient 503 and a 404 that named the wrong instance all
// exited 1, and `-o json` carried "failed" for each. POST /v1/sites emits no
// top-level 403 and no reachable 409, so the exit families that land here are
// 401 → 3 (cloudFail fallthrough), no_team → 1, 404 → 4, every 422 → 1, and
// 502/503 → 8 — NEVER 6.
//
// RED BEFORE (reproducible by reverting cloud_site_cmd.go alone — the create arm
// back to `return cloudFail(out, "create site", cerr)`): barkpark_not_found 404
// exited 1 (want 4), node_ports_exhausted 503 exited 1 (want 8), and
// read_token_mint_failed 502 exited 1 (want 8) — three families collapsed onto
// exitGeneric. The VACUITY guard the verify run flagged is honoured: these assert
// the EXIT CODE per family, not a detail substring (cloudError already folds
// detail into Error(), so a substring check passes on pre-fix bytes too).

// createRefused is the create-with-refusal harness: the create POST answers with
// the given fixture and the mandatory --instance is a UUID (resolved with no
// network call), so the POST is the only request that fires.
func createRefused(t *testing.T, resp fakeResp) (string, string, int) {
	t.Helper()
	cp := newSiteCP(t)
	cp.createResp = resp
	cp.serve()
	return runSite(t, "table", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
}

// no_team is a 422 whose CAUSE (not its status) sets the exit: a teamless login
// stays exit 1 with the `bp team use` fix, never exit 3 — the credential is fine.
func TestRunCloudSiteCreateNoTeamStaysGenericWithTheTeamFix(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{422, `{"error":"no_team"}`})
	if code != exitGeneric {
		t.Fatalf("a no_team refusal must stay exit %d, got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stderr, "bp team use") {
		t.Fatalf("a no_team refusal must point at `bp team use`:\n%s", stderr)
	}
}

// barkpark_not_found is a 404 → exitNotFound, and the sentence points at
// --instance (the thing that was not found), NOT a site slug the user never typed.
// RED BEFORE: cloudFail exited 1 here.
func TestRunCloudSiteCreateBarkparkNotFoundExitsNotFound(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{404, `{"error":"barkpark_not_found"}`})
	if code != exitNotFound {
		t.Fatalf("a 404 barkpark_not_found must exit %d (not-found), got %d\n%s", exitNotFound, code, stderr)
	}
	if !strings.Contains(stderr, "--instance") {
		t.Fatalf("a create 404 must point at --instance, not a site slug:\n%s", stderr)
	}
	if strings.Contains(stderr, "No site was created") == false {
		t.Fatalf("a refused create must say no site was created:\n%s", stderr)
	}
}

// Every 422 the create door emits (content_binding_empty, name_required,
// content_binding_required, barkpark_required, invalid) is exit 1 — the ladder's
// default family. A representative one stands in.
func TestRunCloudSiteCreateInvalidBindingExitsGeneric(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{422, `{"error":"content_binding_empty","detail":"this site's token sees nothing at acme/blog/production for type post"}`})
	if code != exitGeneric {
		t.Fatalf("a 422 create refusal must exit %d (generic), got %d\n%s", exitGeneric, code, stderr)
	}
	if !strings.Contains(stderr, "token sees nothing") {
		t.Fatalf("the default arm must relay the plane's detail:\n%s", stderr)
	}
}

// --- readable-types menu on an empty-binding create refusal (cch-w70, D863) --
//
// content_binding_empty ships a STRUCTURED `readable_types` array (the site's own
// token can see these types) alongside a `detail` that carries a PROSE copy of the
// same menu + the CLI re-run line. The console renders the array (siteReadableTypesMenu)
// and drops the CLI line; the CLI used to relay `detail` whole and never touched
// the array, so a script got the sentence but no list to parse.
//
// The fixture ships THREE rows — two with counts, one WITHOUT (bare type) — so the
// grammar `type (count)` / bare `type` is exercised on one payload, plus a JUNK
// row (empty type) the render must drop.
const emptyBindingBody = `{"error":"content_binding_empty",` +
	`"detail":"this site would build from nothing — its token sees nothing at acme/blog/production. ` +
	`This site CAN read: task (12), paper (40), note. ` +
	"Re-run naming a type this site can read: `bp cloud site create <name> --kind static --framework astro --dataset acme/blog/production --doc-type <type>`\"," +
	`"readable_types":[{"type":"task","count":12},{"type":"paper","count":40},{"type":"note"},{"type":""}]}`

// The HUMAN receipt renders the menu FROM THE ARRAY in the console grammar and
// keeps the bp re-run line. ANTI-VACUITY: it asserts the CLI-COMPOSED line
// (`It can read: task (12), paper (40), note`) which is NOT a substring of the
// server prose (`This site CAN read: …`), and asserts the server prose menu
// sentence is GONE — both red on pre-fix, where the whole detail is relayed
// verbatim (the prose sentence is present and the composed line absent).
func TestRunCloudSiteCreateEmptyBindingRendersReadableTypesMenu(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{422, emptyBindingBody})
	if code != exitGeneric {
		t.Fatalf("a 422 content_binding_empty must exit %d (generic), got %d\n%s", exitGeneric, code, stderr)
	}
	// The array-derived menu, in the console grammar: counts in parens, the
	// count-less row bare, the empty-type junk row dropped.
	if !strings.Contains(stderr, "It can read: task (12), paper (40), note") {
		t.Fatalf("the receipt must render the menu FROM THE ARRAY in console grammar:\n%s", stderr)
	}
	// The server's PROSE menu sentence is replaced, not echoed — proving the CLI
	// composed from the array rather than relaying detail whole (reds pre-fix).
	if strings.Contains(stderr, "This site CAN read:") {
		t.Fatalf("the CLI must compose from the array, not echo the server prose menu:\n%s", stderr)
	}
	// The bp re-run line is the CLI's home — kept, unlike the console which strips it.
	if !strings.Contains(stderr, "--doc-type <type>") {
		t.Fatalf("the CLI must KEEP the bp re-run line:\n%s", stderr)
	}
	if !strings.Contains(stderr, "No site was created") {
		t.Fatalf("a refused create must say no site was created:\n%s", stderr)
	}
}

// The MACHINE envelope carries the menu at error.details.readable_types with the
// server's row ORDER and `type`-before-`count` key order preserved (re-serialized
// from the decoded rows via struct tags — junk rows dropped, never a Go map that
// would alphabetize). ANTI-VACUITY:
// error.details did not exist for this refusal pre-fix, so a decode of
// error.details.readable_types reds outright on pre-fix bytes.
func TestRunCloudSiteCreateEmptyBindingJSONCarriesReadableTypes(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{422, emptyBindingBody}
	cp.serve()
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitGeneric {
		t.Fatalf("a 422 content_binding_empty must exit %d, got %d\n%s", exitGeneric, code, stdout)
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Details struct {
				ReadableTypes []struct {
					Type  string `json:"type"`
					Count *int   `json:"count"`
				} `json:"readable_types"`
			} `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json envelope: %v\n%s", err, stdout)
	}
	if env.OK || env.Error.Code != "content_binding_empty" {
		t.Fatalf("want ok:false code:content_binding_empty:\n%s", stdout)
	}
	got := env.Error.Details.ReadableTypes
	// Server row ORDER preserved, junk row (empty type) dropped upstream.
	if len(got) != 3 || got[0].Type != "task" || got[1].Type != "paper" || got[2].Type != "note" {
		t.Fatalf("error.details.readable_types must carry task,paper,note in order:\n%s", stdout)
	}
	if got[0].Count == nil || *got[0].Count != 12 || got[2].Count != nil {
		t.Fatalf("counts must survive (task=12) and the count-less row stay bare (note):\n%s", stdout)
	}
	// KEY order preserved too — struct-tag order, not a Go map that would alphabetize.
	if !strings.Contains(stdout, `"readable_types":[{"type":"task","count":12}`) {
		t.Fatalf("the raw array bytes must carry the server's key order:\n%s", stdout)
	}
}

// node_ports_exhausted is a 503 → exitServer: the box, not the caller, is out of
// room. RED BEFORE: cloudFail exited 1. A script must be able to tell this
// retry-elsewhere state from a user-fixable 422.
func TestRunCloudSiteCreateNodePortsExhaustedExitsServer(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{503, `{"error":"node_ports_exhausted","detail":"this instance has no free node-slot port left — retire a node site or move to a larger box"}`})
	if code != exitServer {
		t.Fatalf("a 503 node_ports_exhausted must exit %d (server), got %d\n%s", exitServer, code, stderr)
	}
	if !strings.Contains(stderr, "no free node-slot port") {
		t.Fatalf("the 503 must relay the plane's detail:\n%s", stderr)
	}
}

// read_token_mint_failed is a 502 → exitServer, and the human receipt RELAYS the
// plane's detail (the box that refused to mint the site's read token). RED
// BEFORE: cloudFail exited 1.
func TestRunCloudSiteCreateReadTokenMintFailedExitsServerRelayingDetail(t *testing.T) {
	const detail = "acme refused to mint the site's read token (HTTP 403): forbidden"
	_, stderr, code := createRefused(t, fakeResp{502, `{"error":"read_token_mint_failed","detail":"` + detail + `"}`})
	if code != exitServer {
		t.Fatalf("a 502 read_token_mint_failed must exit %d (server), got %d\n%s", exitServer, code, stderr)
	}
	if !strings.Contains(stderr, detail) {
		t.Fatalf("the 502 human receipt must relay the plane's detail verbatim:\n%s", stderr)
	}
}

// read_token_mint_failed in -o json names the plane's OWN code (not "failed") and
// carries exit 8 — so a script can branch on the exact refusal.
func TestRunCloudSiteCreateReadTokenMintFailedJSONCarriesThePlanesCode(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{502, `{"error":"read_token_mint_failed","detail":"acme refused to mint the read token"}`}
	cp.serve()
	stdout, _, code := runSite(t, "json", "create", "--name", "blog", "--dataset", "acme/blog/production", "--instance", testInstanceID)
	if code != exitServer {
		t.Fatalf("a 502 read_token_mint_failed must exit %d, got %d\n%s", exitServer, code, stdout)
	}
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("json envelope: %v\n%s", err, stdout)
	}
	if env.OK {
		t.Fatalf("a refusal envelope must be ok:false:\n%s", stdout)
	}
	if env.Error.Code != "read_token_mint_failed" {
		t.Fatalf("json must carry the plane's code, got %q\n%s", env.Error.Code, stdout)
	}
}

// THE PRESERVED SEAM: a 401 whose message carries the "unauthorized:" prefix still
// routes through cloudFail with the shared `bp login` sentence and the
// byte-identical "create site" label — the ONE refusal that is never about the
// site. This exit (3) is unchanged from the pre-fix behaviour, on purpose.
func TestRunCloudSiteCreateUnauthorizedKeepsTheCloudFailSeam(t *testing.T) {
	_, stderr, code := createRefused(t, fakeResp{401, `{"error":"invalid_token"}`})
	if code != exitAuth {
		t.Fatalf("a 401 must exit %d (auth), got %d\n%s", exitAuth, code, stderr)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("the 401 seam must still tell the user to re-run `bp login`:\n%s", stderr)
	}
	if !strings.Contains(stderr, "create site") {
		t.Fatalf("the 401 seam must keep the byte-identical `create site` label:\n%s", stderr)
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
	// The bound really went on the wire, and it is still ONE call. W11 raised the
	// page from 1 to siteStatusLedgerPage (20) inside that same call so the
	// censored "still waiting" bound can be taken from the OLDEST pending row
	// instead of the newest (= shortest) one; row [0] is still the newest, so this
	// test's subject is unchanged.
	if cp.listHits != 1 {
		t.Fatalf("status must read the deployments list exactly once, got %d hits", cp.listHits)
	}
	if !strings.Contains(cp.listQuery, fmt.Sprintf("limit=%d", siteStatusLedgerPage)) {
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
// plane DID store the binding the receipt says so — and, on an envelope carrying
// NO content_binding key (this fixture), still refuses to claim the dataset serves
// that type, because nothing in THIS envelope has read it.
//
// ssw8 narrowed what that means. The verdict is no longer invisible to the CLI —
// CreateSpawnSite decodes the top-level content_binding key and renderSiteCreated
// prints it — so the receipt can no longer say the verdict "is not in this
// envelope" as a standing fact. What it must still do is tell an ABSENT verdict
// apart from a bad one: this create was answered without one, so the line reports
// the stored row and says no create-time verdict came with it, and the loop below
// still refuses any bound/unverified narration.
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
	// The receipt must not narrate the create-time binding check's RESULT: THIS
	// envelope carried none. Saying so is honest; reporting how it came out would
	// be quoting a read this process was never shown.
	if !strings.Contains(stdout, "no create-time verdict") {
		t.Fatalf("the receipt must say this envelope carried no verdict:\n%s", stdout)
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

// TestRunCloudSiteStatusShowsDeferralChainDepth is the CONSUMER half of dr-w7 S1
// (deploy-reliability charter D99, PR #9905). Before it, `git grep -n 'deferred'
// internal/cli/cloud_site_cmd.go` returned NOTHING: a settled `deferred` row —
// the box refusing a build round while a rebuild is already re-queued — had no
// dedicated render at all, so an operator saw a bare status word and could not
// tell a first blip from a chain eight rounds deep. On the production ledger 63
// capacity-deferred rows across five sites all carried the SAME sentence.
func TestRunCloudSiteStatusShowsDeferralChainDepth(t *testing.T) {
	const deferredReason = "the instance refused the deploy (HTTP 409): box_at_capacity — the box is at its build capacity (1 of 1 build slots in use) — deferred: refusal 8 of 12 in this site's current chain — a rebuild carrying this content has been re-queued and will run once the in-flight deploy finishes"

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production","url":"https://acme.barkpark.cloud/sites/blog/",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"deferred","stage":"PLAN",` +
		`"failure_reason":` + mustJSONString(deferredReason) + `,"failure_class":"BOX_AT_CAPACITY_DEFERRED","environment":"production"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	// THE ROW THAT DID NOT EXIST: the chain gets its own legible element, with
	// the depth, the CAUSE's own bound, and what is actually being counted — a
	// bare "8 of 12" would read as a countdown to a drop a merely-slow box may
	// never reach (one site deferred 75 times in 12h and never came within 4).
	for _, want := range []string{
		"deferral",
		"refusal 8 of 12 consecutive",
		"SAME cause",
		"any successful deploy resets it to 0",
		"zero-progress guard, not a countdown",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("status must render the deferral chain %q:\n%s", want, stdout)
		}
	}
	// A deferral is NOT a failure, and the header must not borrow the vocabulary:
	// the rebuild is re-queued, not lost.
	if strings.Contains(stdout, "NEWEST deploy FAILED") {
		t.Fatalf("a deferred newest row must not be reported as FAILED:\n%s", stdout)
	}
	if !strings.Contains(stdout, "DEFERRED") || !strings.Contains(stdout, "re-queued") {
		t.Fatalf("status must say the newest deploy was deferred and re-queued:\n%s", stdout)
	}
	// The live pointer is still named — that older build IS what visitors see.
	if !strings.Contains(stdout, "dep-1") || !strings.Contains(stdout, "dep-9") {
		t.Fatalf("status must name both the live and the deferred row:\n%s", stdout)
	}

	// …and the machine envelope carries the pair as NUMBERS, so a script can
	// threshold on depth instead of grepping a sentence.
	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Latest struct {
			Status string `json:"status"`
			Depth  *int   `json:"deferral_depth"`
			Bound  *int   `json:"deferral_bound"`
		} `json:"latest_deployment"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if env.Latest.Status != "deferred" {
		t.Fatalf("latest_deployment must stay the deferred row: %+v\n%s", env.Latest, jstdout)
	}
	if env.Latest.Depth == nil || *env.Latest.Depth != 8 {
		t.Fatalf("latest_deployment.deferral_depth must be 8: %+v\n%s", env.Latest, jstdout)
	}
	if env.Latest.Bound == nil || *env.Latest.Bound != 12 {
		t.Fatalf("latest_deployment.deferral_bound must be 12: %+v\n%s", env.Latest, jstdout)
	}
}

// TestRunCloudSiteStatusDeferralPreD99 is the fail-honest arm: a control plane
// that predates D99 writes a deferral sentence with NO depth in it, and the CLI
// must say the chain depth is unavailable rather than print a zero — a "refusal
// 0 of 0" would read as "no chain", which is the exact inversion of the truth.
func TestRunCloudSiteStatusDeferralPreD99(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production"}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"deferred","stage":"PLAN",` +
		`"failure_reason":"the instance refused the deploy (HTTP 409): box_at_capacity - deferred: a rebuild carrying this content has been re-queued",` +
		`"failure_class":"BOX_AT_CAPACITY_DEFERRED","environment":"production"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "does not report how deep the refusal chain is") {
		t.Fatalf("a pre-D99 deferral must say the depth is unavailable:\n%s", stdout)
	}
	if strings.Contains(stdout, "refusal 0") {
		t.Fatalf("an unparseable chain must never print a zero depth:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	if strings.Contains(jstdout, "deferral_depth") {
		t.Fatalf("json must omit deferral_depth entirely when the CP did not say it:\n%s", jstdout)
	}
}

// TestSiteDeferralChainNotOnFailedRows keeps the two vocabularies apart: the
// `deferral_*` keys ride ONLY a deferred row. A failed row is a drop, not a
// re-queue, and giving it deferral keys would let a dashboard count a lost
// publish as a waiting one.
//
// ITS ORIGINAL RATIONALE WAS FALSE, and dr-w29-s7 corrects it rather than
// deleting the property. The comment used to claim "the terminal round does"
// quote a chain — meaning `refusal N of M`. It does not: that clause is written
// only on the DEFERRED branch (cloud/lib/barkpark_cloud/sites/deploy.ex:1302),
// and 0 of 7 live abandoned rows match it. The first fixture below is therefore
// a sentence NO producer emits; the second is the real one, from
// `abandonment_reason/3` (deploy.ex:1424), and it is the case that actually had
// to be defended. Both must stay free of `deferral_*` — the abandoned row gets
// `abandonment_*` instead (TestSiteAbandonmentChainReachesTheJSONEnvelope).
func TestSiteDeferralChainNotOnFailedRows(t *testing.T) {
	rows := map[string]cloudclient.SiteDeployment{
		"a sentence no producer emits": {
			ID:            "dep-x",
			Status:        "failed",
			FailureReason: "…and it has now refused 12 rebuilds in a row for this site (refusal 12 of 12)",
		},
		"the real abandonment sentence": {
			ID:            "dep-y",
			Status:        "failed",
			FailureClass:  "ABANDONED_AT_CAPACITY",
			FailureReason: siteAbandonmentSentence(12, "so the instance has been at its concurrent-build cap for that entire run; check for builds holding slots without finishing, or raise the cap"),
			DeferralDepth: siteIntPtr(12),
			DeferralBound: siteIntPtr(12),
			DeferralCause: strPtr("BOX_AT_CAPACITY_DEFERRED"),
		},
	}
	for name, failed := range rows {
		m := siteDeploymentMap(failed)
		for _, k := range []string{"deferral_depth", "deferral_bound", "deferral_cause"} {
			if _, ok := m[k]; ok {
				t.Fatalf("%s: a failed row must not carry %s: %+v", name, k, m)
			}
		}
		if siteDeployDeferred(failed.Status) {
			t.Fatalf("%s: siteDeployDeferred must not match a failed row", name)
		}
	}
}

// siteAbandonmentSentence rebuilds `Sites.Deploy.abandonment_reason/3`'s output
// byte-for-byte (cloud/lib/barkpark_cloud/sites/deploy.ex:1424):
//
//	reason <> " — and it has now refused #{rounds} rebuilds in a row for this site, #{terminal_verdict(cause)}"
//
// The fixture goes through this one helper so the Go reader is pinned to the
// PRODUCER's template rather than to a paraphrase of it — the same discipline
// deploy_ledger_test.exs applies from the Elixir side.
func siteAbandonmentSentence(rounds int, verdict string) string {
	return fmt.Sprintf(
		"the instance refused the deploy (HTTP 409): box_at_capacity — and it has now refused %d rebuilds in a row for this site, %s",
		rounds, verdict)
}

// TestSiteAbandonmentChainReachesTheJSONEnvelope is the dr-w29-s7 defect in one
// fixture. Before it, an abandoned row lost ALL THREE chain numbers from
// `bp cloud site status -o json` while `failure_class: ABANDONED_AT_CAPACITY`
// survived — the machine surface was strictly WORSE than the human one, which
// still printed "refused 12 rebuilds in a row" in prose.
//
// MUTATION PROOF: delete the `siteDeployAbandoned` block in siteDeploymentMap
// and this test reds on the first key — the exact silence being fixed.
func TestSiteAbandonmentChainReachesTheJSONEnvelope(t *testing.T) {
	m := siteDeploymentMap(cloudclient.SiteDeployment{
		ID:            "dep-abandoned",
		Status:        "failed",
		FailureClass:  "ABANDONED_BOX_STUCK",
		FailureReason: siteAbandonmentSentence(6, "so the instance is not busy but stuck; check its deploy runner"),
		DeferralDepth: siteIntPtr(6),
		DeferralBound: siteIntPtr(6),
	})
	if got := m["abandonment_depth"]; got != 6 {
		t.Fatalf("abandonment_depth = %v, want 6: %+v", got, m)
	}
	if got := m["abandonment_bound"]; got != 6 {
		t.Fatalf("abandonment_bound = %v, want 6: %+v", got, m)
	}
	if got := m["abandonment_cause"]; got != "ABANDONED_BOX_STUCK" {
		t.Fatalf("abandonment_cause = %v, want the ledger class: %+v", got, m)
	}
	// The keys are DISTINCT, never an alias: a reader summing `deferral_depth`
	// must not silently start counting given-up publishes as waiting ones.
	for _, k := range []string{"deferral_depth", "deferral_bound", "deferral_cause"} {
		if _, ok := m[k]; ok {
			t.Fatalf("an abandoned row must not borrow the deferral key %s: %+v", k, m)
		}
	}
	// It renders, byte for byte, as JSON a script can threshold on.
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, want := range []string{`"abandonment_bound":6`, `"abandonment_depth":6`, `"abandonment_cause":"ABANDONED_BOX_STUCK"`} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("rendered JSON missing %s:\n%s", want, b)
		}
	}
}

// TestSiteAbandonmentDepthFallsBackToTheProducersSentence covers the seven live
// rows that predate the columns (charter D504 rules NO BACKFILL, so they are the
// only population that can prove this arm is reachable). Depth comes off the
// producer's own clause and the cause off the class — and `abandonment_bound` is
// ABSENT, never a zero: the bound is not in the sentence, and re-deriving 12/6
// in Go would hardcode the other cause's budget (D195).
func TestSiteAbandonmentDepthFallsBackToTheProducersSentence(t *testing.T) {
	m := siteDeploymentMap(cloudclient.SiteDeployment{
		ID:           "dep-old",
		Status:       "failed",
		FailureClass: "ABANDONED_AT_CAPACITY",
		FailureReason: siteAbandonmentSentence(12,
			"so the instance has been at its concurrent-build cap for that entire run; check for builds holding slots without finishing, or raise the cap"),
	})
	if got := m["abandonment_depth"]; got != 12 {
		t.Fatalf("the prose fallback must read the depth off the producer's clause, got %v: %+v", got, m)
	}
	if got := m["abandonment_cause"]; got != "ABANDONED_AT_CAPACITY" {
		t.Fatalf("abandonment_cause = %v: %+v", got, m)
	}
	if v, ok := m["abandonment_bound"]; ok {
		t.Fatalf("an unknown bound must be ABSENT, not %v: %+v", v, m)
	}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(b), `"abandonment_bound"`) {
		t.Fatalf("no bound key may be rendered at all:\n%s", b)
	}
	// The RAW capture carries the clause when FailureReason is the humanizer's
	// generic arm — the fallback reads that too, or those rows stay silent.
	raw := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-raw", Status: "failed", FailureClass: "ABANDONED_UNCLASSIFIED",
		FailureReason:    "the deploy did not complete",
		FailureReasonRaw: siteAbandonmentSentence(9, "so the instance is refusing this site persistently for a cause the ledger cannot name; check its deploy runner"),
	})
	if got := raw["abandonment_depth"]; got != 9 {
		t.Fatalf("the raw capture must be read too, got %v: %+v", got, raw)
	}
}

// TestSiteAbandonmentKeysOnlyOnAbandonedRows pins the gate to the ledger CLASS.
// An ordinary build failure — even a deep chain that was merely deferred — never
// grows abandonment keys, and a class-less failed row emits nothing at all.
func TestSiteAbandonmentKeysOnlyOnAbandonedRows(t *testing.T) {
	rows := map[string]cloudclient.SiteDeployment{
		"an ordinary build failure": {
			ID: "dep-b", Status: "failed", FailureClass: "BUILD_EXIT_NONZERO",
			FailureReason: "the build exited 1", DeferralDepth: siteIntPtr(3), DeferralBound: siteIntPtr(12),
		},
		"a failed row with no class at all": {
			ID: "dep-c", Status: "failed",
			FailureReason: siteAbandonmentSentence(12, "so the instance is not busy but stuck; check its deploy runner"),
		},
		"a live row": {ID: "dep-d", Status: "live"},
	}
	for name, d := range rows {
		m := siteDeploymentMap(d)
		for _, k := range []string{"abandonment_depth", "abandonment_bound", "abandonment_cause"} {
			if _, ok := m[k]; ok {
				t.Fatalf("%s must not carry %s: %+v", name, k, m)
			}
		}
	}
	if !siteDeployAbandoned("ABANDONED_UNCLASSIFIED") {
		t.Fatal("the class predicate must match every ABANDONED_* member")
	}
	if siteDeployAbandoned("BOX_AT_CAPACITY_DEFERRED") || siteDeployAbandoned("") {
		t.Fatal("the class predicate must not match a deferral class or an empty class")
	}
}

// TestSiteDeferralCauseReachesTheJSONEnvelope closes the third silent drop:
// `deferral_cause` has been decoded since #10248 and emitted nowhere, so a
// script could read how deep a chain ran and never WHY. It rides a DEFERRED row
// only, and only when the control plane actually sent it.
func TestSiteDeferralCauseReachesTheJSONEnvelope(t *testing.T) {
	m := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-def", Status: "deferred",
		FailureReason: "the instance refused the deploy (HTTP 409): box_at_capacity — deferred: refusal 3 of 12 in this site's current chain — a rebuild carrying this content has been re-queued",
		DeferralDepth: siteIntPtr(3), DeferralBound: siteIntPtr(12),
		DeferralCause: strPtr("BOX_AT_CAPACITY_DEFERRED"),
	})
	if got := m["deferral_cause"]; got != "BOX_AT_CAPACITY_DEFERRED" {
		t.Fatalf("deferral_cause = %v, want the ledger class: %+v", got, m)
	}
	if m["deferral_depth"] != 3 || m["deferral_bound"] != 12 {
		t.Fatalf("the depth pair must be unchanged: %+v", m)
	}
	// A pre-#10248 box sends no cause, and silence stays silence.
	old := siteDeploymentMap(cloudclient.SiteDeployment{
		ID: "dep-old-def", Status: "deferred",
		FailureReason: "the instance refused the deploy (HTTP 409): box_at_capacity — deferred: refusal 3 of 12 in this site's current chain — a rebuild carrying this content has been re-queued",
	})
	if _, ok := old["deferral_cause"]; ok {
		t.Fatalf("a control plane that sent no cause must yield no key: %+v", old)
	}
	if old["deferral_depth"] != 3 {
		t.Fatalf("the prose fallback for the depth pair must still work: %+v", old)
	}
}

// TestRunCloudSiteStatusFailedNewestBeatsDeferredLivePointer pins the ORDER of
// the two half-truth arms the status header now carries. Both write `reason`,
// and the deferral arm runs second — so before the dr-w7 review fix, a header
// whose newest row FAILED while the live pointer was itself a deferred row said
// "the NEWEST deploy FAILED" and then printed the OLDER deferral's sentence
// underneath, describing a different row than the status line named. A drop is
// the louder truth: it wins, and no deferral row is printed at all.
func TestRunCloudSiteStatusFailedNewestBeatsDeferredLivePointer(t *testing.T) {
	const deferredReason = "the instance refused the deploy (HTTP 409): box_at_capacity — deferred: refusal 3 of 12 in this site's current chain — a rebuild carrying this content has been re-queued"

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"deferred","stage":"PLAN","failure_reason":` + mustJSONString(deferredReason) + `}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"failed","stage":"BUILD",` +
		`"failure_reason":"the build exited 1: astro could not resolve @layouts/Base.astro","failure_class":"BUILD_EXIT_NONZERO","environment":"production"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "NEWEST deploy FAILED") {
		t.Fatalf("a failed newest row must still be reported as failed:\n%s", stdout)
	}
	if !strings.Contains(stdout, "astro could not resolve") {
		t.Fatalf("the reason row must describe the FAILED newest row, not the deferred pointer:\n%s", stdout)
	}
	if strings.Contains(stdout, "refusal 3 of 12") || strings.Contains(stdout, "deferral ") {
		t.Fatalf("no deferral section may be printed when the newest row is a drop:\n%s", stdout)
	}
}

// --- dr-w12 S7: the waiting clock counts the one shape that IS an unbounded wait -

// TestSiteWaitingSinceMeasuresADeferralChainFromItsStart is the whole slice in one
// fixture. Before it, siteDeployWaiting read `!terminal && !deferred`, so
// siteWaitingSince skipped every refused round — and a refusal chain is precisely
// the shape whose wait is unbounded, since a refusal can be followed by a refusal
// forever. On the production ledger deferrals are 53.6% of attempts, and the
// operator's censored bound over all of them was NOTHING.
//
// MUTATION / BEFORE-AFTER PROOF: `git checkout HEAD -- internal/cli/cloud_site_cmd.go`
// (this test calls only siteWaitingSince and siteTimeToWebLine, both of which
// predate the slice, so the package still compiles) and this test REDS with
// "measured no wait at all" — the exact silence being fixed.
func TestSiteWaitingSinceMeasuresADeferralChainFromItsStart(t *testing.T) {
	ttwFreeze(t)
	dep := &cloudclient.SiteDeployment{
		ID: "dep-live", Status: "live",
		InsertedAt: ttwStamp(9 * time.Hour), BecameLiveAt: ttwStamp(8*time.Hour - 5*time.Minute),
	}
	chainReason := func(depth int) string {
		return fmt.Sprintf("the instance refused the deploy (HTTP 409): box_at_capacity — deferred: refusal %d of 12 in this site's current chain — a rebuild carrying this content has been re-queued", depth)
	}
	// Newest-first, as the page arrives: four rounds of ONE chain. Each round is
	// its own row with its own inserted_at, and the newest one is the SHORTEST wait
	// in the chain — reading it would report 2m for a publish that has been stuck
	// for over three hours.
	ledger := []cloudclient.SiteDeployment{
		{ID: "dep-r4", Status: "deferred", InsertedAt: ttwStamp(2 * time.Minute), FailureReason: chainReason(4)},
		{ID: "dep-r3", Status: "deferred", InsertedAt: ttwStamp(21 * time.Minute), FailureReason: chainReason(3)},
		{ID: "dep-r2", Status: "deferred", InsertedAt: ttwStamp(58 * time.Minute), FailureReason: chainReason(2)},
		{ID: "dep-r1", Status: "deferred", InsertedAt: ttwStamp(3*time.Hour + 5*time.Minute), FailureReason: chainReason(1)},
		*dep,
	}

	waited, id, ok := siteWaitingSince(dep, ledger)
	if !ok {
		t.Fatal("a four-round deferral chain measured no wait at all — the clock is still blind to the one shape that is unbounded")
	}
	if waited != 3*time.Hour+5*time.Minute {
		t.Fatalf("the wait must run from the FIRST refused attempt (3h05m), got %s", waited)
	}
	if id != "dep-r1" {
		t.Fatalf("the bound must name the chain's START row, got %q", id)
	}

	line := siteTimeToWebLine(dep, ledger)
	if !strings.Contains(line, "at least 3h05m so far") {
		t.Fatalf("the printed bound must be the chain's, got %q", line)
	}
	for _, shorter := range []string{"at least 2m", "at least 21m", "at least 58m"} {
		if strings.Contains(line, shorter) {
			t.Fatalf("the newest refusal is the shortest wait in the chain and must never be the bound (%s): %q", shorter, line)
		}
	}
	// The clock is measured from the START, the DEPTH is read off the head — two
	// different rows, because "how deep am I now" is only true on the latest round.
	// Quoting the measured row's own sentence would print "refusal 1 of 12" over a
	// chain four rounds deep.
	if !strings.Contains(line, "refusal 4 of 12 consecutive") {
		t.Fatalf("the depth must come from the NEWEST refusal, not the row the clock was measured from: %q", line)
	}
	if strings.Contains(line, "refusal 1 of 12") {
		t.Fatalf("the chain-start row's stale depth must not be printed as the current one: %q", line)
	}
	// The WAIT leads; the depth is a detail behind it. The chain is bounded and
	// small (24h p50 3, max 11) while the wait it produces is not, so a header that
	// opened with the depth would lead with the least alarming number on the row.
	if i, j := strings.Index(line, "still waiting"), strings.Index(line, "refusal 4 of 12"); i < 0 || j < 0 || i > j {
		t.Fatalf("the wait must be printed BEFORE the chain depth: %q", line)
	}
	// Depth-of-fence, never a bare count — and never a chain-derived rate
	// (charter D174/D142: chains carry no key, so any percentage over them is
	// unfalsifiable and era-unstable).
	for _, want := range []string{"of 12 consecutive", "zero-progress guard, not a countdown", "any successful deploy resets it to 0"} {
		if !strings.Contains(line, want) {
			t.Fatalf("the depth must carry its fence and what it counts (%q): %q", want, line)
		}
	}
	if strings.Contains(line, "%") {
		t.Fatalf("no chain-derived rate may be printed: %q", line)
	}
}

// TestSiteWaitingClauseNamesItsClock: #10189 landed the NAME THE CLOCK law on this
// surface for the time-to-web number, and the censored wait had been printing a
// bare duration beside it. The two clocks are 7.1x apart at p50 and 13.6x at p95
// on IDENTICAL rows (publish-keyed p50 235s vs row-keyed p50 33s) — a duration
// that does not say which one it is has an order of magnitude of slack in it.
func TestSiteWaitingClauseNamesItsClock(t *testing.T) {
	ttwFreeze(t)
	ledger := []cloudclient.SiteDeployment{
		{ID: "dep-q", Status: "queued", InsertedAt: ttwStamp(40 * time.Minute)},
	}
	line := siteTimeToWebLine(nil, ledger)
	if !strings.Contains(line, "at least 40m00s so far") {
		t.Fatalf("the censored bound must be printed: %q", line)
	}
	for _, want := range []string{"inserted_at", "not from your publish", "60s of debounce"} {
		if !strings.Contains(line, want) {
			t.Fatalf("every printed wait must disclose whose clock it is (%q): %q", want, line)
		}
	}
	// A queued row is not a refused one: no chain vocabulary may attach to it.
	if strings.Contains(line, "REFUSED") || strings.Contains(line, "refusal") {
		t.Fatalf("a slow build is not a refusal chain: %q", line)
	}
}

// TestSiteWaitingChainDegradesWhenTheControlPlaneIsSilent is the able-to-lose arm,
// and it is the reason the pre-D99 branch in siteDeferralLine is kept rather than
// tidied away: a box that does not report chain depth must produce a wait that
// SAYS the depth is unavailable, not a wait with a zero in it. "refusal 0 of 0"
// would read as "no chain" — the exact inversion of the truth.
func TestSiteWaitingChainDegradesWhenTheControlPlaneIsSilent(t *testing.T) {
	ttwFreeze(t)
	ledger := []cloudclient.SiteDeployment{
		{ID: "dep-d2", Status: "deferred", InsertedAt: ttwStamp(6 * time.Minute),
			FailureReason: "the instance refused the deploy (HTTP 409): box_at_capacity - deferred: a rebuild carrying this content has been re-queued"},
		{ID: "dep-d1", Status: "deferred", InsertedAt: ttwStamp(52 * time.Minute),
			FailureReason: "the instance refused the deploy (HTTP 409): box_at_capacity - deferred: a rebuild carrying this content has been re-queued"},
	}
	line := siteTimeToWebLine(nil, ledger)
	// The WAIT survives the silence — it is measured from stamps the row carries,
	// not from the sentence it does not.
	if !strings.Contains(line, "at least 52m00s so far") {
		t.Fatalf("an unreported chain must still be timed from its start: %q", line)
	}
	if !strings.Contains(line, "does not report how deep the refusal chain is") {
		t.Fatalf("a silent control plane must be named as silent: %q", line)
	}
	if strings.Contains(line, "refusal 0") {
		t.Fatalf("an unparseable chain must never print a zero depth: %q", line)
	}
}

// TestSiteStalenessCarriesTheChainBesideTheWait is the machine twin: a script that
// pages a fleet should be able to separate "a build is slow" from "the box keeps
// refusing", without grepping prose. The flag rides ONLY a deferred bound (never a
// `false` on the others, which would read as a measurement the CLI did not make),
// and the depth pair rides only a control plane that actually said it.
func TestSiteStalenessCarriesTheChainBesideTheWait(t *testing.T) {
	ttwFreeze(t)
	newest := &cloudclient.SiteDeployment{ID: "dep-r2", Status: "deferred"}
	chain := []cloudclient.SiteDeployment{
		{ID: "dep-r2", Status: "deferred", InsertedAt: ttwStamp(4 * time.Minute),
			FailureReason: "box_at_capacity — deferred: refusal 7 of 12 in this site's current chain"},
		{ID: "dep-r1", Status: "deferred", InsertedAt: ttwStamp(80 * time.Minute),
			FailureReason: "box_at_capacity — deferred: refusal 6 of 12 in this site's current chain"},
	}
	m := siteStalenessMap(nil, newest, chain)
	if m["latest_waiting_seconds_at_least"] != int64(80*60) {
		t.Fatalf("the censored bound must be the chain start's 80m, got %v", m["latest_waiting_seconds_at_least"])
	}
	if m["latest_waiting_deferred"] != true {
		t.Fatalf("a refused wait must be flagged as one: %+v", m)
	}
	if m["latest_waiting_deferral_depth"] != 7 || m["latest_waiting_deferral_bound"] != 12 {
		t.Fatalf("the depth pair must come from the chain HEAD (7 of 12): %+v", m)
	}
	// No rate, no percentage, ever: chains have no key and the closed-live rate is
	// era-unstable (48.4% over 7d vs 28.3% over 24h) — charter D174/D142.
	for k := range m {
		if strings.Contains(k, "rate") || strings.Contains(k, "percent") {
			t.Fatalf("no chain-derived rate may reach the envelope: %q", k)
		}
	}

	// A slow build carries neither the flag nor the pair — absence means "not a
	// refusal", which is the only honest shape for a fact we did not measure.
	slow := []cloudclient.SiteDeployment{{ID: "dep-q", Status: "building", InsertedAt: ttwStamp(11 * time.Minute)}}
	q := siteStalenessMap(nil, &cloudclient.SiteDeployment{ID: "dep-q", Status: "building"}, slow)
	for _, k := range []string{"latest_waiting_deferred", "latest_waiting_deferral_depth", "latest_waiting_deferral_bound"} {
		if _, present := q[k]; present {
			t.Fatalf("%s must be ABSENT on a non-refused wait: %+v", k, q)
		}
	}
}

// --- deploy-reliability W14 (charter D213/D214/D220/D221) ---------------------
//
// THE READER STOPPED PARSING ENGLISH, THE PARAGRAPH NAMED ITS WINDOW, AND THE ONE
// CLAUSE THE DATA CONTRADICTED STOPPED BEING ASSERTED.
//
// Every human-paragraph proof below is captured with runSite(t, "table", …), and
// that is load-bearing rather than habit: internal/cli/output.go:74-80 picks the
// format by TTY when -o is absent, so a piped or agent-captured run gets RAW
// JSON. A test that captured stdout without pinning "table" would assert against
// JSON and pass while the paragraph it claims to fix went untouched.

// siteIntPtr is the wire shape of the deferral columns: *int, absent on every row
// written before 2026-08-07T10:12:35Z.
func siteIntPtr(v int) *int { return &v }

// TestSiteDeferralChainPrefersTheColumnsOverTheProse is the column-first,
// prose-fallback contract in one table.
//
// THE DISAGREEMENT CASE IS THE POINT. A row whose columns say 9 of 12 while its
// sentence still says 3 of 6 must render the COLUMN — the sentence is a snapshot
// the control plane wrote at defer time and the columns are what it computed. If
// the fallback ever won that tie, this reader would be a regex with extra steps.
//
// AND THE NULL CASE IS WHY THE REGEX STAYS. The columns are stamped on 116 of
// 1,934 post-boundary deferred rows (6.0%), and the boundary is a HARD STEP: NULL
// is exactly equivalent to "this row predates 2026-08-07T10:12:35Z". A column-only
// reader over a pre-boundary window reads 100% NULL for the WHOLE window — it
// loses the window, not a slice of it.
func TestSiteDeferralChainPrefersTheColumnsOverTheProse(t *testing.T) {
	const prose36 = "box_at_capacity — deferred: refusal 3 of 6 in this site's current chain"
	cases := []struct {
		name               string
		row                cloudclient.SiteDeployment
		wantDepth, wantBnd int
		wantOK             bool
	}{
		{
			name: "columns WIN a disagreement with the prose",
			row: cloudclient.SiteDeployment{
				ID: "dep-c", Status: "deferred", FailureReason: prose36,
				DeferralDepth: siteIntPtr(9), DeferralBound: siteIntPtr(12),
			},
			wantDepth: 9, wantBnd: 12, wantOK: true,
		},
		{
			name: "NULL columns fall back to the prose, which still renders",
			row: cloudclient.SiteDeployment{
				ID: "dep-p", Status: "deferred", FailureReason: prose36,
			},
			wantDepth: 3, wantBnd: 6, wantOK: true,
		},
		{
			name: "a zero DEPTH column is no chain — and does NOT re-read the prose",
			row: cloudclient.SiteDeployment{
				ID: "dep-z", Status: "deferred", FailureReason: prose36,
				DeferralDepth: siteIntPtr(0), DeferralBound: siteIntPtr(12),
			},
			wantOK: false,
		},
		{
			name: "a zero BOUND column is no chain — and does NOT re-read the prose",
			row: cloudclient.SiteDeployment{
				ID: "dep-b", Status: "deferred", FailureReason: prose36,
				DeferralDepth: siteIntPtr(4), DeferralBound: siteIntPtr(0),
			},
			wantOK: false,
		},
		{
			name: "half a pair is not a pair: depth without bound falls back",
			row: cloudclient.SiteDeployment{
				ID: "dep-h", Status: "deferred", FailureReason: prose36,
				DeferralDepth: siteIntPtr(9),
			},
			wantDepth: 3, wantBnd: 6, wantOK: true,
		},
		{
			name:   "neither columns nor a parseable sentence is honestly nothing",
			row:    cloudclient.SiteDeployment{ID: "dep-n", Status: "deferred", FailureReason: "box_at_capacity — deferred: a rebuild has been re-queued"},
			wantOK: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			depth, bound, ok := siteDeferralChain(tc.row)
			if ok != tc.wantOK {
				t.Fatalf("ok=%v want %v (depth=%d bound=%d)", ok, tc.wantOK, depth, bound)
			}
			if !ok {
				// The zero-guard: a refused read must produce NOTHING, never a
				// "refusal 0 of 0", which reads as "no chain" — the exact inversion.
				if depth != 0 || bound != 0 {
					t.Fatalf("a refused read must return zeros and ok=false, got %d of %d", depth, bound)
				}
				return
			}
			if depth != tc.wantDepth || bound != tc.wantBnd {
				t.Fatalf("got %d of %d, want %d of %d", depth, bound, tc.wantDepth, tc.wantBnd)
			}
		})
	}
}

// TestRunCloudSiteStatusRendersTheColumnDepthOverTheProse carries the same
// disagreement all the way to the surface an owner actually reads: the columns
// are on the wire, the sentence contradicts them, and the paragraph prints 9 of 12
// while -o json carries the same pair as numbers.
func TestRunCloudSiteStatusRendersTheColumnDepthOverTheProse(t *testing.T) {
	const prose = "the instance refused the deploy (HTTP 409): box_at_capacity — deferred: refusal 3 of 6 in this site's current chain — a rebuild carrying this content has been re-queued"

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"deferred","stage":"PLAN",` +
		`"failure_reason":` + mustJSONString(prose) + `,"failure_class":"BOX_AT_CAPACITY_DEFERRED",` +
		`"deferral_depth":9,"deferral_bound":12,"deferral_cause":"BOX_AT_CAPACITY_DEFERRED","environment":"production"}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "refusal 9 of 12 consecutive") {
		t.Fatalf("the COLUMN depth must win over the sentence:\n%s", stdout)
	}
	if strings.Contains(stdout, "refusal 3 of 6 consecutive") {
		t.Fatalf("the stale prose pair must not be rendered as the chain:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env struct {
		Latest struct {
			Depth *int `json:"deferral_depth"`
			Bound *int `json:"deferral_bound"`
		} `json:"latest_deployment"`
	}
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	if env.Latest.Depth == nil || *env.Latest.Depth != 9 || env.Latest.Bound == nil || *env.Latest.Bound != 12 {
		t.Fatalf("the json pair must be the columns' 9 of 12: %+v\n%s", env.Latest, jstdout)
	}
}

// TestSiteDeferralBoundIsNeverHardcodedTo12 pins the OTHER bound. The control
// plane's max_consecutive_deferrals is 12 for BOX_AT_CAPACITY_DEFERRED and 6 for
// everything else, and prod carries real "of 6" rows — a renderer that assumed 12
// would print a fence twice as far away as the one the row is measured against.
func TestSiteDeferralBoundIsNeverHardcodedTo12(t *testing.T) {
	cause := "BOX_BUSY_DEFERRED"
	col := cloudclient.SiteDeployment{
		ID: "dep-busy", Status: "deferred", FailureClass: "BOX_BUSY_DEFERRED",
		DeferralDepth: siteIntPtr(5), DeferralBound: siteIntPtr(6),
		DeferralCause: &cause,
	}
	if line := siteDeferralLine(col); !strings.Contains(line, "refusal 5 of 6 consecutive") {
		t.Fatalf("a bound-6 cause must render its own fence: %q", line)
	}
	prose := cloudclient.SiteDeployment{
		ID: "dep-busy-old", Status: "deferred", FailureClass: "BOX_BUSY_DEFERRED",
		FailureReason: "the instance refused the deploy (HTTP 409): box_busy — deferred: refusal 5 of 6 in this site's current chain",
	}
	if line := siteDeferralLine(prose); !strings.Contains(line, "refusal 5 of 6 consecutive") {
		t.Fatalf("the prose arm must carry the row's own bound too: %q", line)
	}
	if strings.Contains(siteDeferralLine(col)+siteDeferralLine(prose), "of 12") {
		t.Fatalf("no renderer may substitute the capacity bound for this cause's")
	}
}

// TestRunCloudSiteStatusNamesTheWindowItRead is the census: the paragraph now says
// how many attempts it read, over what span, and how many of them the box refused
// — with a denominator beside every count.
//
// The fixture is majority-deferred on purpose, because that is the shape the
// surface used to render as six green ticks: search-capstone's reachable 200-row
// window was 148 deferred / 47 live / 5 failed and the header named none of it.
func TestRunCloudSiteStatusNamesTheWindowItRead(t *testing.T) {
	ttwFreeze(t)
	rows := []string{
		`{"id":"dep-1","site_id":"` + testSiteID + `","status":"live","inserted_at":"2026-08-07T10:29:17Z","became_live_at":"2026-08-07T10:29:48Z"}`,
	}
	// 12 refused rounds and one failed round, newest first (the page's own order).
	stamps := []string{
		"2026-08-07T10:20:00Z", "2026-08-07T10:10:00Z", "2026-08-07T10:00:00Z",
		"2026-08-07T09:50:00Z", "2026-08-07T09:40:00Z", "2026-08-07T09:30:00Z",
		"2026-08-07T09:20:00Z", "2026-08-07T09:10:00Z", "2026-08-07T09:00:00Z",
		"2026-08-07T08:50:00Z", "2026-08-07T08:40:00Z", "2026-08-07T08:30:00Z",
	}
	for i, ts := range stamps {
		rows = append(rows, fmt.Sprintf(`{"id":"dep-d%d","site_id":"%s","status":"deferred","inserted_at":%q,"failure_class":"BOX_AT_CAPACITY_DEFERRED","deferral_depth":%d,"deferral_bound":12}`,
			i, testSiteID, ts, len(stamps)-i))
	}
	rows = append(rows, `{"id":"dep-f","site_id":"`+testSiteID+`","status":"failed","inserted_at":"2026-08-07T01:32:34Z","failure_class":"BUILD_FAILED"}`)

	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[` + strings.Join(rows, ",") + `],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	for _, want := range []string{
		"recent attempts (the window this status read",
		"14 attempts read, from 2026-08-07T01:32:34Z to 2026-08-07T10:29:17Z",
		"12 of 14 deferred by the box",
		"1 of 14 live",
		"1 of 14 failed",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the window paragraph must carry %q:\n%s", want, stdout)
		}
	}
	// A count without a denominator is the defect this block exists to fix — and a
	// derived share is banned outright (charter D174/D142: chains carry no key, so
	// any percentage over them is unfalsifiable and era-unstable).
	if strings.Contains(stdout, "%") {
		t.Fatalf("the window must print counts with denominators, never a rate:\n%s", stdout)
	}
	// The census is its OWN block after the KV table, not KV rows — renderKV sorts
	// alphabetically and pads to the widest key, so census rows would scatter
	// between `dataset` and `framework` and widen the whole header.
	kvEnd := strings.Index(stdout, "recent attempts")
	if kvEnd < 0 {
		t.Fatalf("no window block at all:\n%s", stdout)
	}
	if i := strings.Index(stdout, "dataset"); i < 0 || i > kvEnd {
		t.Fatalf("the window block must come AFTER the KV table:\n%s", stdout)
	}

	jstdout, _, jcode := runSite(t, "json", "status", testSiteID)
	if jcode != exitOK {
		t.Fatalf("status -o json exit=%d want 0", jcode)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(jstdout), &env); err != nil {
		t.Fatalf("status json not parseable: %v\n%s", err, jstdout)
	}
	win, ok := env["window"].(map[string]any)
	if !ok {
		t.Fatalf("the window must be its OWN sibling node, not a staleness key:\n%s", jstdout)
	}
	stale, _ := env["staleness"].(map[string]any)
	if _, folded := stale["attempts_read"]; folded {
		t.Fatalf("the census must not be folded into staleness:\n%s", jstdout)
	}
	for k, want := range map[string]float64{"attempts_read": 14, "deferred_count": 12, "live_count": 1, "failed_count": 1} {
		if win[k] != want {
			t.Fatalf("window.%s = %v want %v\n%s", k, win[k], want, jstdout)
		}
	}
	if win["oldest_inserted_at"] != "2026-08-07T01:32:34Z" || win["newest_inserted_at"] != "2026-08-07T10:29:17Z" {
		t.Fatalf("the window must name the span it ACTUALLY saw: %+v", win)
	}
	// The three substring guards this node has to live under: two enforced on
	// siteStalenessMap's keys, and `deferral_depth` scanned over the whole
	// serialized stdout by TestRunCloudSiteStatusDeferralPreD99.
	for k := range win {
		for _, banned := range []string{"rate", "percent", "deferral_depth"} {
			if strings.Contains(k, banned) {
				t.Fatalf("window key %q carries the banned substring %q", k, banned)
			}
		}
	}
}

// TestSiteWindowRefusesASpanItCannotProve: a page whose rows carry no readable
// inserted_at gets NO span rather than a 1970 one, and the rows are counted out
// loud instead of silently vanishing from the denominator.
func TestSiteWindowRefusesASpanItCannotProve(t *testing.T) {
	w, ok := siteReadWindow([]cloudclient.SiteDeployment{
		{ID: "dep-a", Status: "deferred"},
		{ID: "dep-b", Status: "deferred", InsertedAt: "not-a-timestamp"},
	})
	if !ok {
		t.Fatal("a page with rows is still a window")
	}
	if w.Oldest != "" || w.Newest != "" {
		t.Fatalf("an unprovable span must stay empty, got %q..%q", w.Oldest, w.Newest)
	}
	if w.Rows != 2 || w.Deferred != 2 || w.Stampless != 2 {
		t.Fatalf("stampless rows must still be counted: %+v", w)
	}
	m := siteWindowMap(w)
	for _, k := range []string{"oldest_inserted_at", "newest_inserted_at"} {
		if _, present := m[k]; present {
			t.Fatalf("%s must be ABSENT when unprovable, never a zero instant: %+v", k, m)
		}
	}
	if m["attempts_without_a_stamp"] != 2 {
		t.Fatalf("the unstamped rows must be reported: %+v", m)
	}
	// An EMPTY page is not a window at all — an absent census means "could not
	// read the ledger", which a zeroed one would hide.
	if _, ok := siteReadWindow(nil); ok {
		t.Fatal("an empty ledger must produce no window node")
	}
}

// TestSiteWindowSaysThePageRanOut: the page is siteStatusLedgerPage rows, so a
// full page means older attempts exist that this status never read. Saying so is
// the difference between a bounded read and an implied history.
func TestSiteWindowSaysThePageRanOut(t *testing.T) {
	full := make([]cloudclient.SiteDeployment, siteStatusLedgerPage)
	for i := range full {
		full[i] = cloudclient.SiteDeployment{ID: fmt.Sprintf("dep-%d", i), Status: "deferred", InsertedAt: ttwStamp(time.Duration(i) * time.Minute)}
	}
	w, _ := siteReadWindow(full)
	if !w.PageFull {
		t.Fatalf("a full page must be flagged as full: %+v", w)
	}
	var buf bytes.Buffer
	out := newWriter(&buf, &buf)
	renderSiteWindow(out, w)
	if !strings.Contains(buf.String(), "older attempts exist that this status did not read") {
		t.Fatalf("a full page must say the read ran out:\n%s", buf.String())
	}
	short, _ := siteReadWindow(full[:3])
	if short.PageFull {
		t.Fatalf("a short page must NOT claim it ran out: %+v", short)
	}
}

// TestRunCloudSiteStatusDoesNotPromiseARequeueItCannotSee is charter D213, and it
// is the sharpest correction in this slice.
//
// Both deferred-newest status lines used to end "(a rebuild is already re-queued)"
// UNCONDITIONALLY. The CLI cannot see that: on site `search`, 47 of 523 content_rev
// chains are deferred-only with no live and no failed row, and every one of them
// got that promise. The single most reassuring clause in the owner paragraph was
// the one the data contradicted.
//
// The replacement is a BLIND SPOT, not a loss claim — charter D212 settles the
// abandonment as benign supersession (227 of 227 settled abandoned chains have a
// later live row on the same site, ZERO do not), so "your publish was lost" would
// be a second false claim pointing the other way.
func TestRunCloudSiteStatusDoesNotPromiseARequeueItCannotSee(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[{"id":"dep-9","site_id":"` + testSiteID + `","status":"deferred","stage":"PLAN","inserted_at":"2026-08-07T10:20:00Z",` +
		`"failure_class":"BOX_AT_CAPACITY_DEFERRED","deferral_depth":4,"deferral_bound":12}],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	if strings.Contains(stdout, "a rebuild is already re-queued") {
		t.Fatalf("the CLI must not assert a re-queue no row on the page shows:\n%s", stdout)
	}
	for _, want := range []string{
		"the NEWEST deploy was DEFERRED by the box",
		"nothing newer than it is on the page this status read",
		"not visible from here",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the deferred header must name its blind spot (%q):\n%s", want, stdout)
		}
	}
	// The register is "we cannot see one", never a loss claim (charter D212).
	for _, banned := range []string{"was lost", "dropped your", "abandoned"} {
		if strings.Contains(stdout, banned) {
			t.Fatalf("a benign supersession must not be narrated as a loss (%q):\n%s", banned, stdout)
		}
	}
}

// TestSiteRequeueVisibleNeedsANewerUnsettledRow is the other arm of the same
// predicate: it says YES only on evidence, and the evidence is narrow on purpose.
// A newer FAILED or LIVE row is not the refused round being retried, and an
// unparseable stamp on either side proves nothing — refusing to guess here is
// exactly what the unconditional clause failed to do.
func TestSiteRequeueVisibleNeedsANewerUnsettledRow(t *testing.T) {
	refused := cloudclient.SiteDeployment{ID: "dep-d", Status: "deferred", InsertedAt: "2026-08-07T10:00:00Z"}
	newerQueued := cloudclient.SiteDeployment{ID: "dep-q", Status: "queued", InsertedAt: "2026-08-07T10:05:00Z"}
	newerLive := cloudclient.SiteDeployment{ID: "dep-l", Status: "live", InsertedAt: "2026-08-07T10:05:00Z"}
	olderQueued := cloudclient.SiteDeployment{ID: "dep-o", Status: "queued", InsertedAt: "2026-08-07T09:00:00Z"}
	stampless := cloudclient.SiteDeployment{ID: "dep-s", Status: "queued"}

	if !siteRequeueVisible(refused, []cloudclient.SiteDeployment{newerQueued, refused}) {
		t.Fatal("a newer unsettled row IS a visible re-queue")
	}
	for _, ledger := range [][]cloudclient.SiteDeployment{
		{newerLive, refused},
		{refused, olderQueued},
		{stampless, refused},
		{refused},
		nil,
	} {
		if siteRequeueVisible(refused, ledger) {
			t.Fatalf("no evidence of a re-queue in %+v", ledger)
		}
	}
	// A refused row with no stamp of its own can order nothing and must refuse.
	if siteRequeueVisible(cloudclient.SiteDeployment{ID: "dep-d", Status: "deferred"}, []cloudclient.SiteDeployment{newerQueued}) {
		t.Fatal("an unstamped refused row cannot prove anything is newer than it")
	}
	if c := siteRequeueClause(refused, []cloudclient.SiteDeployment{newerQueued, refused}); !strings.Contains(c, "already on this site's ledger") {
		t.Fatalf("a proven re-queue may be claimed: %q", c)
	}
}

// TestRunCloudSiteStatusWindowOverAFailedNewestFixture proves the census on the
// newest-failed-over-an-older-live shape BY FIXTURE, and that is deliberate:
// charter D228h measured the population EMPTY across all 13 sites (the two
// failed-newest sites have no older live row at all), so a criterion phrased
// against a live site would have forced a fabricated pass.
func TestRunCloudSiteStatusWindowOverAFailedNewestFixture(t *testing.T) {
	cp := newSiteCP(t)
	cp.getResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"blog","slug":"blog","kind":"static","framework":"astro","workspace":"acme","project":"blog","dataset":"production",` +
		`"current_deployment":{"id":"dep-1","status":"live","stage":"RETIRE","stages":[{"name":"PLAN","status":"done"}]}}}`}
	cp.listResp = fakeResp{200, `{"deployments":[` +
		`{"id":"dep-9","site_id":"` + testSiteID + `","status":"failed","stage":"BUILD","inserted_at":"2026-08-07T11:00:00Z","failure_reason":"the build command exited non-zero — nothing was switched","failure_class":"BUILD_FAILED"},` +
		`{"id":"dep-1","site_id":"` + testSiteID + `","status":"live","inserted_at":"2026-08-07T09:00:00Z","became_live_at":"2026-08-07T09:01:00Z"}` +
		`],"next_cursor":null}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "status", testSiteID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\n%s", code, stderr)
	}
	// The staleness arm is untouched — the census rides BESIDE it, never over it.
	if !strings.Contains(stdout, "NEWEST deploy FAILED") {
		t.Fatalf("the failed-newest half-truth must survive the census:\n%s", stdout)
	}
	for _, want := range []string{
		"2 attempts read, from 2026-08-07T09:00:00Z to 2026-08-07T11:00:00Z",
		"0 of 2 deferred by the box",
		"1 of 2 live",
		"1 of 2 failed",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the window must carry %q:\n%s", want, stdout)
		}
	}
}

// TestSiteWindowAccountsForEveryRowItRead is the review fix (W14): the census's
// buckets must be EXHAUSTIVE over the page it read.
//
// The first cut counted deferred/live/failed/waiting only, so a `cancelled` row
// landed in no bucket at all: the paragraph printed "12 of 20 deferred · 3 of 20
// live · 1 of 20 failed", the reader subtracted, and the remaining rows were
// simply gone with no name and no note. That is the same class of defect as the
// unnamed window one layer up — a census that cannot account for its own
// denominator invites the reader to invent the difference.
//
// The identity is asserted on the STRUCT (so it holds for every caller) and the
// unnamed residue is proven to surface in the human block rather than vanish.
func TestSiteWindowAccountsForEveryRowItRead(t *testing.T) {
	ledger := []cloudclient.SiteDeployment{
		{ID: "d1", Status: "deferred", InsertedAt: "2026-08-07T10:00:00Z"},
		{ID: "d2", Status: "live", InsertedAt: "2026-08-07T09:00:00Z"},
		{ID: "d3", Status: "failed", InsertedAt: "2026-08-07T08:00:00Z"},
		{ID: "d4", Status: "building", InsertedAt: "2026-08-07T07:00:00Z"},
		{ID: "d5", Status: "cancelled", InsertedAt: "2026-08-07T06:00:00Z"},
		{ID: "d6", Status: "canceled", InsertedAt: "2026-08-07T05:00:00Z"},
		{ID: "d7", Status: "quiesced-by-a-word-this-cli-has-never-seen", InsertedAt: "2026-08-07T04:00:00Z"},
		{ID: "d8", Status: "", InsertedAt: "2026-08-07T03:00:00Z"},
	}
	w, ok := siteReadWindow(ledger)
	if !ok {
		t.Fatal("a page with rows is a window")
	}
	sum := w.Deferred + w.Live + w.Failed + w.Waiting + w.Cancelled + w.Other
	if sum != w.Rows {
		t.Fatalf("the buckets must account for every row read: %d != %d (%+v)", sum, w.Rows, w)
	}
	if w.Cancelled != 2 {
		t.Fatalf("both spellings of cancelled must be counted: %+v", w)
	}
	// A status word this CLI has never seen is still NON-TERMINAL, so it is a wait
	// — the honest reading, and the reason `other` is a narrow safety net rather
	// than a catch-all. Only a row carrying no status at all lands there.
	if w.Waiting != 2 {
		t.Fatalf("an unrecognised non-terminal status is a wait: %+v", w)
	}
	if w.Other != 1 {
		t.Fatalf("a status-less row must land in the named residue, not in nothing: %+v", w)
	}

	var buf bytes.Buffer
	renderSiteWindow(newWriter(&buf, &buf), w)
	for _, want := range []string{
		"2 of 8 cancelled",
		"1 of 8 in another state this CLI does not name",
	} {
		if !strings.Contains(buf.String(), want) {
			t.Fatalf("the residue must be printed, not dropped (%q):\n%s", want, buf.String())
		}
	}

	m := siteWindowMap(w)
	// Emitted at zero too, or the identity is unwritable by a machine reader.
	empty, _ := siteReadWindow([]cloudclient.SiteDeployment{{ID: "d1", Status: "live", InsertedAt: "2026-08-07T10:00:00Z"}})
	for _, k := range []string{"cancelled_count", "other_count"} {
		if _, present := m[k]; !present {
			t.Fatalf("%s missing from the json census: %+v", k, m)
		}
		if _, present := siteWindowMap(empty)[k]; !present {
			t.Fatalf("%s must be present even at zero: %+v", k, siteWindowMap(empty))
		}
	}
	// And the census's own key guards still hold for the new keys.
	for k := range m {
		for _, banned := range []string{"rate", "percent", "deferral_depth"} {
			if strings.Contains(k, banned) {
				t.Fatalf("window key %q carries the banned substring %q", k, banned)
			}
		}
	}
}

// TestSiteStatusRendersTheBuildIdentity is dr-w23-s6's reader half, and it is
// deliberately a test of RENDERED BYTES rather than of the struct.
//
// A struct assertion (`dep.GitRef == "…"`) would have passed the moment the tag
// was declared, while `bp cloud site status` still printed nothing — which is
// the exact failure this slice exists to end. So the test drives the real wire
// through the real decoder into the real renderer: JSON bytes the control plane
// actually sends -> json.Unmarshal -> spawnSiteStatusMap -> renderKV -> stdout.
//
// The four keys rode this payload all along; `SiteDeployment` simply declared no
// field for them, so json.Unmarshal dropped them silently. See the struct comment
// in internal/cloudclient/client.go for why the payload census could not say so.
func TestSiteStatusRendersTheBuildIdentity(t *testing.T) {
	// The WIRE, not a hand-built struct: site_deployment_json/3 pipes the narrow
	// deployment_json/1, which is why the wide payload carries these at top level.
	const wire = `{
	  "id": "dep-abc",
	  "site_id": "site-1",
	  "status": "live",
	  "stage": "serve",
	  "git_ref": "refs/heads/main@9f2c1ab",
	  "artifact_url": "https://cdn.example/builds/9f2c1ab.tar.zst",
	  "image_tag": "barkpark/site-blog:9f2c1ab",
	  "detail": "served from slot b after a health-gated switch"
	}`

	var dep cloudclient.SiteDeployment
	if err := json.Unmarshal([]byte(wire), &dep); err != nil {
		t.Fatalf("the wire payload must decode: %v", err)
	}

	// ANTI-VACUITY: prove the DECODE happened before asserting on the render. If
	// the tags were dropped, every render assertion below would fail with the
	// same message and blame the renderer for a decoder bug.
	for _, tc := range []struct{ name, got, want string }{
		{"GitRef", dep.GitRef, "refs/heads/main@9f2c1ab"},
		{"ArtifactURL", dep.ArtifactURL, "https://cdn.example/builds/9f2c1ab.tar.zst"},
		{"ImageTag", dep.ImageTag, "barkpark/site-blog:9f2c1ab"},
		{"Detail", dep.Detail, "served from slot b after a health-gated switch"},
	} {
		if tc.got != tc.want {
			t.Fatalf("SiteDeployment.%s did not DECODE: got %q, want %q — the json tag is missing, not the render", tc.name, tc.got, tc.want)
		}
	}

	site := cloudclient.SpawnSite{ID: testSiteID, Name: "blog", Slug: "blog", Kind: "static", Framework: "astro"}
	out, buf, _ := newTestWriter()
	renderKV(out, spawnSiteStatusMap(site, &dep, &dep, []cloudclient.SiteDeployment{dep}))
	stdout := buf.String()

	// THE RENDER, which is the whole point: each key must reach the screen with
	// its value beside it.
	for _, want := range []string{
		"git ref",
		"refs/heads/main@9f2c1ab",
		"image tag",
		"barkpark/site-blog:9f2c1ab",
		"artifact",
		"https://cdn.example/builds/9f2c1ab.tar.zst",
		"detail",
		"served from slot b after a health-gated switch",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("`bp cloud site status` must render %q — the wide reader is still poorer than `bp sites`:\n%s", want, stdout)
		}
	}
}

// TestSiteStatusDetailDoesNotEchoTheReason pins the one judgment in the render
// above: the top-level `detail` and the failure `reason` are the same string
// family (both come from Sites.Deploy.stage_caption/2), so on a failed row they
// are frequently byte-identical. Printing both would put one sentence on the
// screen twice and teach a reader that one of the two rows is noise.
//
// It is suppressed ONLY when it duplicates; a detail that says something the
// reason did not must still appear, which is the second half of this test and
// the reason the guard is not simply "never print detail on a failed row".
func TestSiteStatusDetailDoesNotEchoTheReason(t *testing.T) {
	site := cloudclient.SpawnSite{ID: testSiteID, Name: "blog", Slug: "blog", Kind: "static", Framework: "astro"}
	const same = "the build command exited non-zero"

	dup := &cloudclient.SiteDeployment{ID: "dep-1", Status: "failed", FailureReason: same, Detail: same}
	out, buf, _ := newTestWriter()
	renderKV(out, spawnSiteStatusMap(site, dup, dup, nil))

	if n := strings.Count(buf.String(), same); n != 1 {
		t.Errorf("a detail identical to the reason must print ONCE, got %d occurrences:\n%s", n, buf.String())
	}

	differs := &cloudclient.SiteDeployment{
		ID: "dep-2", Status: "failed", FailureReason: same,
		Detail: "npm ERR! missing script: build",
	}
	out2, buf2, _ := newTestWriter()
	renderKV(out2, spawnSiteStatusMap(site, differs, differs, nil))

	if !strings.Contains(buf2.String(), "npm ERR! missing script: build") {
		t.Errorf("a detail that differs from the reason must still be rendered:\n%s", buf2.String())
	}
}

// TestSiteFailureClassRowStripsANSILocally pins wbt-go-ledger-hygiene-sweep's
// one proof obligation: the "failure class" row on `bp cloud site status`
// must never carry a raw control byte to the terminal, even though strip_ansi
// was added at the JSON boundary server-side and NOT in this Go printer.
//
// It asserts on the RENDERED row — spawnSiteStatusMap → renderKV — rather
// than calling sanitizeCell directly. The value is sanitized TWICE on this
// path today: once where it is set (cloud_site_cmd.go:2229-2230 ->
// hzCell at hetzner_cmd.go:415) and again by renderKV's own cellString
// (table.go:428-433), both of which bottom out in sanitizeCell
// (table.go:456). MUTATION PROOF: dropping EITHER call site alone still
// leaves the other guarding the render, so this test stays green — it is
// sanitizeCell itself that is load-bearing; no-opping it (`return s` instead
// of the strings.Map body) reds this test immediately:
//
//	--- FAIL: TestSiteFailureClassRowStripsANSILocally (0.00s)
//	    the rendered "failure class" row carried a raw ESC byte — sanitizeCell
//	    must strip it before the terminal sees it:
//	    "...failure class  BUILD_FAILED \x1b[31mred\x1b[0m exit 1..."
//
// restoring sanitizeCell's body goes back to green. That is the real
// regression this guards: EITHER call site may move or be refactored away
// (cellString's backstop means hzCell's own call is not strictly load-bearing
// today), but sanitizeCell dropping C0/DEL bytes from a table cell must not.
func TestSiteFailureClassRowStripsANSILocally(t *testing.T) {
	const poisoned = "BUILD_FAILED \x1b[31mred\x1b[0m exit 1"
	dep := &cloudclient.SiteDeployment{ID: "dep-1", Status: "failed", FailureClass: poisoned}
	site := cloudclient.SpawnSite{ID: testSiteID, Name: "blog", Slug: "blog", Kind: "static", Framework: "astro"}

	out, buf, _ := newTestWriter()
	renderKV(out, spawnSiteStatusMap(site, dep, dep, []cloudclient.SiteDeployment{*dep}))
	stdout := buf.String()

	if strings.ContainsRune(stdout, 0x1b) {
		t.Fatalf("the rendered \"failure class\" row carried a raw ESC byte — sanitizeCell must strip it before the terminal sees it:\n%q", stdout)
	}
	if !strings.Contains(stdout, "failure class") {
		t.Fatalf("siteFailureClass(dep, newest) was non-empty but no \"failure class\" row rendered:\n%s", stdout)
	}
	if !strings.Contains(stdout, "BUILD_FAILED") || !strings.Contains(stdout, "red") || !strings.Contains(stdout, "exit 1") {
		t.Errorf("stripping the ESC bytes must not eat the surrounding readable text:\n%s", stdout)
	}
}

// --- typed deploy refusals (cch-w71, D866) -----------------------------------
//
// `bp cloud site deploy` and its --prebuilt sub-steps used to hand EVERY refusal
// to the bare cloudFail(out, "deploy site", derr) — a seam that branches only on
// a dead session (HTTP 401). So a 422 the user can fix, a 409 the plane refused,
// a 404 that named a deployment id from a shell history and a 503 that started
// no build ALL printed "failed" and exited 1, and `-o json` carried "failed" for
// each. A script could not tell "your input is wrong" from "retry in a minute".
// They now exit by the #11784 family ladder via siteRefusalFail, the same one
// rollback / delete / create ride.
//
// THE TABLE BELOW IS DERIVED FROM THE LIVE ROUTE ARMS, not invented. The deploy
// plane is one Plug.Router — cloud/lib/barkpark_cloud/web/router.ex, module
// BarkparkCloud.Web.Router — and every fixture here is a status+code pair that
// module actually emits:
//
//	401 unauthorized ........ Auth.require_user/2, Auth.require_user_or_pat/2
//	403 forbidden ........... Auth.require_ability/2 (required/scope, NO reason)
//	404 not_found ........... Router.with_team_site/3, and each route body's own
//	                          deployment-miss arm
//	409 ..................... upload_deployment_artifact/3 (deployment_not_queued),
//	                          settle_deployment_artifact/5 (artifact_conflict),
//	                          do_bind_cloudflare/5 (instance_not_live)
//	413 artifact_too_large .. receive_deployment_artifact/3
//	422 ..................... deploy_static_site/2 (no_content_binding,
//	                          prebuilt_not_enabled, unknown_source,
//	                          instance_not_live), receive_deployment_artifact/3
//	                          (artifact_digest_mismatch, not_prebuilt), the list
//	                          arm (invalid_cursor)
//	5xx ..................... 503 deploy_not_started (deploy_static_site/2 and
//	                          start_prebuilt_deploy/5), 500 upload_failed
//	                          (receive_deployment_artifact/3), 502
//	                          cloudflare_bind_failed (do_bind_cloudflare/5),
//	                          500 server_error (Router.handle_errors/2 crash slug)
//
// Two arms are deliberately ABSENT because the plane does not emit them here: a
// teamless caller is answered 404 by with_team_site/3 (never 403 no_team), and
// identity_refused is minted only by Sites.Deploy.rollback/2 and .teardown/2 — a
// box that refuses a DEPLOY surfaces as 503 deploy_not_started instead.
//
// RED BEFORE (reproducible by reverting cloud_site_cmd.go alone — the seven
// deploy-chain arms back to their bare cloudFail calls): every non-401 row below
// exited 1. 403 wanted 3, 404 wanted 4, every 409 wanted 6, and 500/502/503
// wanted 8 — four families collapsed onto exitGeneric. VACUITY GUARD: these
// assert the EXIT CODE per status, never a detail substring — cloudError already
// folds `detail` into Error(), so a substring check passes on pre-fix bytes too.
// The 401 rows are the INVARIANT half: they were exit 3 before and must stay 3,
// because siteRefusalFail deliberately routes 401 back through cloudFail so the
// "session expired? run `bp login` again" sentence stays the one every cloud verb
// prints.

// siteExitName renders an exit code as the family it names, so a failure message
// reads "want 6 (conflict), got 1 (generic)" instead of two bare integers.
func siteExitName(code int) string {
	switch code {
	case exitOK:
		return "ok"
	case exitGeneric:
		return "generic"
	case exitUsage:
		return "usage"
	case exitAuth:
		return "auth"
	case exitNotFound:
		return "not-found"
	case exitConflict:
		return "conflict"
	case exitServer:
		return "server"
	default:
		return "?"
	}
}

// siteRefusalCase is one row of a per-status exit table.
type siteRefusalCase struct {
	name string
	resp fakeResp
	want int
}

// deployRefused drives `bp cloud site deploy <uuid>` against a control plane that
// answers the deploy POST with the given fixture. The ref is a UUID, so
// resolveOpenSiteID passes it through and the POST is the only request that fires.
func deployRefused(t *testing.T, resp fakeResp) (string, int) {
	t.Helper()
	cp := newSiteCP(t)
	cp.deployResp = resp
	cp.serve()
	_, stderr, code := runSite(t, "table", "deploy", testSiteID)
	return stderr, code
}

// POST /v1/sites/:id/deploy — the deploy verb itself.
func TestRunCloudSiteDeployExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		// The invariant: 401 keeps the shared dead-session seam and its `bp login`
		// sentence. Not red before — it is here so a future edit cannot quietly
		// pull 401 onto the ladder and lose that copy.
		{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
		// Auth.require_ability/2 — the caller's token lacks `write` on this team.
		{"403 forbidden", fakeResp{403, `{"error":"forbidden","required":"write","scope":"token"}`}, exitAuth},
		// Router.with_team_site/3 — wrong team, missing site, or a teamless login.
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		// do_bind_cloudflare/5 — the box was deprovisioned mid-bind.
		{"409 instance_not_live", fakeResp{409, `{"error":"instance_not_live","detail":"deprovisioned while this request was in flight"}`}, exitConflict},
		{"409 no_cloudflare_provider", fakeResp{409, `{"error":"no_cloudflare_provider","detail":"no cloudflare credential on this team"}`}, exitConflict},
		// deploy_static_site/2's 422 family — all user-fixable, all exit 1.
		{"422 no_content_binding", fakeResp{422, `{"error":"no_content_binding","detail":"this site has no bootstrap dataset"}`}, exitGeneric},
		{"422 prebuilt_not_enabled", fakeResp{422, `{"error":"prebuilt_not_enabled","detail":"enable it with bp cloud site settings"}`}, exitGeneric},
		{"422 unknown_source", fakeResp{422, `{"error":"unknown_source","detail":"sources: box, prebuilt"}`}, exitGeneric},
		{"422 instance_not_live", fakeResp{422, `{"error":"instance_not_live","detail":"the instance has no URL yet"}`}, exitGeneric},
		{"422 invalid", fakeResp{422, `{"error":"invalid","details":{"source":["is invalid"]}}`}, exitGeneric},
		// The 5xx family — transient, retryable, exit 8.
		{"503 deploy_not_started", fakeResp{503, `{"error":"deploy_not_started","detail":"the deployment row was created but the build driver could not be started — nothing is building.","reason":"the deploy could not be started — the box is busy; retry shortly"}`}, exitServer},
		{"502 cloudflare_bind_failed", fakeResp{502, `{"error":"cloudflare_bind_failed","detail":"the zone write failed"}`}, exitServer},
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stderr, code := deployRefused(t, tc.resp)
			if code != tc.want {
				t.Fatalf("a %s deploy refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
		})
	}
}

// A refused deploy must say NO BUILD WAS STARTED. The bare cloudFail said only
// "deploy site: <slug>", which leaves a reader unable to tell whether a build is
// now running against bytes they did not mean to ship.
func TestRunCloudSiteDeployRefusalSaysNoBuildStarted(t *testing.T) {
	stderr, code := deployRefused(t, fakeResp{422, `{"error":"no_content_binding","detail":"this site has no bootstrap dataset"}`})
	if code != exitGeneric {
		t.Fatalf("exit=%d want %d\n%s", code, exitGeneric, stderr)
	}
	if !strings.Contains(stderr, "No build was started") {
		t.Fatalf("a refused deploy must say no build was started:\n%s", stderr)
	}
	if !strings.Contains(stderr, "no bootstrap dataset") {
		t.Fatalf("the default arm must relay the plane's own detail:\n%s", stderr)
	}
}

// deploy_not_started is the ONE deploy refusal where something WAS written: the
// deployment row exists and is audited, but no build driver started. The plane
// splits that into `detail` (what is not running, what to do) and `reason` (why,
// in one retry-actionable clause from Router.transport_reason/1). The bare
// cloudFail exited 1, which reads to a script as "your input is wrong"; it is 8.
func TestRunCloudSiteDeployNotStartedIsServerFamilyAndCarriesBothHalves(t *testing.T) {
	stderr, code := deployRefused(t, fakeResp{503, `{"error":"deploy_not_started","detail":"the deployment row was created but the build driver could not be started — nothing is building.","reason":"the deploy could not be started — the box is busy; retry shortly"}`})
	if code != exitServer {
		t.Fatalf("a 503 deploy_not_started must exit %d (server), got %d (%s)\n%s",
			exitServer, code, siteExitName(code), stderr)
	}
	if !strings.Contains(stderr, "nothing is building") {
		t.Fatalf("the receipt must relay the plane's detail half:\n%s", stderr)
	}
	if !strings.Contains(stderr, "the box is busy") {
		t.Fatalf("the receipt must relay the plane's reason half — it is the retry-actionable clause:\n%s", stderr)
	}
}

// POST /v1/sites/:id/deploy {"source":"prebuilt"} — the MINT sub-step. Same route
// as the deploy verb, so the same families land; the sentences differ because a
// refused mint leaves no deployment to ship bytes to.
func TestRunCloudSitePrebuiltMintExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		{"403 forbidden", fakeResp{403, `{"error":"forbidden","required":"write","scope":"token"}`}, exitAuth},
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		{"422 prebuilt_not_enabled", fakeResp{422, `{"error":"prebuilt_not_enabled","detail":"enable it with bp cloud site settings"}`}, exitGeneric},
		{"503 deploy_not_started", fakeResp{503, `{"error":"deploy_not_started","detail":"nothing is building"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeDistFixture(t, "b0b0b0b0b0b0b0b0")
			cp := newSiteCP(t)
			cp.deployResp = tc.resp
			cp.serve()
			_, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
			if code != tc.want {
				t.Fatalf("a %s mint refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
			if !strings.Contains(stderr, "No deployment was minted") {
				t.Fatalf("a refused mint must say no deployment was minted:\n%s", stderr)
			}
		})
	}
}

// POST /v1/sites/:id/deployments/:dep_id/artifact — the UPLOAD sub-step. The mint
// succeeds first, so a refusal here leaves a deployment that IS minted and still
// queued; that is the state the copy must name.
func TestRunCloudSiteArtifactUploadExitsByStatusFamily(t *testing.T) {
	const buildID = "b0b0b0b0b0b0b0b0"
	for _, tc := range []siteRefusalCase{
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		// upload_deployment_artifact/3 and settle_deployment_artifact/5.
		{"409 deployment_not_queued", fakeResp{409, `{"error":"deployment_not_queued","detail":"this deployment is already building"}`}, exitConflict},
		{"409 artifact_conflict", fakeResp{409, `{"error":"artifact_conflict","detail":"a different sha is already stored"}`}, exitConflict},
		// receive_deployment_artifact/3. An oversize artifact is USER-FIXABLE (ship
		// fewer bytes), so 413 belongs on the generic family, never the transient one.
		{"413 artifact_too_large", fakeResp{413, `{"error":"artifact_too_large","max_bytes":33554432}`}, exitGeneric},
		{"422 artifact_digest_mismatch", fakeResp{422, `{"error":"artifact_digest_mismatch","detail":"declared sha does not match the bytes"}`}, exitGeneric},
		{"422 not_prebuilt", fakeResp{422, `{"error":"not_prebuilt","detail":"this is a box-build row"}`}, exitGeneric},
		{"500 upload_failed", fakeResp{500, `{"error":"upload_failed","reason":"the request could not be completed"}`}, exitServer},
		{"503 deploy_not_started", fakeResp{503, `{"error":"deploy_not_started","detail":"the artifact was stored but the build driver could not be started"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeDistFixture(t, buildID)
			cp := newSiteCP(t)
			cp.deployResp = fakeResp{201, `{"deployment":{"id":"dep-1","site_id":"` + testSiteID + `","status":"queued","stage":"PLAN","build_id":"` + buildID + `","content_rev":"cr-42","source":"prebuilt"}}`}
			cp.artifactResp = tc.resp
			cp.serve()
			_, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir)
			if cp.artifactHits != 1 {
				t.Fatalf("the artifact route was hit %d times — the fixture never reached the arm under test\n%s", cp.artifactHits, stderr)
			}
			if code != tc.want {
				t.Fatalf("a %s upload refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
			// The state-after that only this kind can state: the row survives, and
			// --deployment resumes it rather than minting a fresh (nonced) build id.
			if !strings.Contains(stderr, "--deployment") {
				t.Fatalf("a refused upload must point at --deployment — the deployment is still queued:\n%s", stderr)
			}
		})
	}
}

// GET /v1/sites/:id/deployments/:dep_id — the POLL sub-step, mid-stream. A refused
// READ must never read as a refused DEPLOY: the build is still running on the box.
func TestRunCloudSiteDeployPollExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cp := newSiteCP(t)
			cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
			cp.pollResp = tc.resp
			cp.serve()
			_, stderr, code := runSite(t, "table", "deploy", testSiteID)
			if cp.pollHits == 0 {
				t.Fatalf("the poll route was never hit — the fixture never reached the arm under test\n%s", stderr)
			}
			if code != tc.want {
				t.Fatalf("a %s poll refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
		})
	}
}

// The honesty half of the poll conversion: a lost poll is not a lost deploy.
func TestRunCloudSiteDeployPollRefusalSaysTheBuildIsStillRunning(t *testing.T) {
	cp := newSiteCP(t)
	cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
	cp.pollResp = fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}
	cp.serve()
	_, stderr, code := runSite(t, "table", "deploy", testSiteID)
	if code != exitServer {
		t.Fatalf("exit=%d want %d\n%s", code, exitServer, stderr)
	}
	if !strings.Contains(stderr, "still running on the box") {
		t.Fatalf("a refused poll must say the build is untouched and still running:\n%s", stderr)
	}
}

// GET /v1/sites/:id/deployments/:dep_id — the pre-flight READ of a `--deployment`
// id. A stale id pasted from a shell history is a 404, and it now exits 4: the
// bare cloudFail exited 1, which is what a bad flag value exits, so a script
// could not tell a typo'd id from a broken deploy.
func TestRunCloudSiteReadNamedDeploymentExitsByStatusFamily(t *testing.T) {
	for _, tc := range []siteRefusalCase{
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := writeDistFixture(t, "b0b0b0b0b0b0b0b0")
			cp := newSiteCP(t)
			cp.pollResp = tc.resp
			cp.serve()
			_, stderr, code := runSite(t, "table", "deploy", testSiteID, "--prebuilt", dir, "--deployment", "dep-404")
			if cp.deployHits != 0 {
				t.Fatalf("--deployment must not mint: the deploy route was hit %d times\n%s", cp.deployHits, stderr)
			}
			if code != tc.want {
				t.Fatalf("a %s named-deployment read must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
			// The refusal names the DEPLOYMENT id, not the site: that is the thing
			// that was not found, and the id is the only value the user can fix.
			if !strings.Contains(stderr, "dep-404") {
				t.Fatalf("the refusal must name the deployment id it could not read:\n%s", stderr)
			}
		})
	}
}

// GET /v1/sites/:id/deployments — the LIST read --wait-for-live loops on. A
// refusal here loses the WATCH, never the deploy: the re-queued rebuild is still
// queued.
func TestRunCloudSiteWaitForLiveListRefusalExitsByStatusFamily(t *testing.T) {
	const deferred = `{"deployment":{"id":"dep-1","status":"deferred","stage":"BUILD","environment":"production","inserted_at":"2026-08-23T10:00:00Z","stages":[]}}`
	for _, tc := range []siteRefusalCase{
		{"401 unauthorized", fakeResp{401, `{"error":"unauthorized"}`}, exitAuth},
		{"404 not_found", fakeResp{404, `{"error":"not_found"}`}, exitNotFound},
		{"422 invalid_cursor", fakeResp{422, `{"error":"invalid_cursor","detail":"that cursor is not decodable"}`}, exitGeneric},
		{"500 server_error", fakeResp{500, `{"error":"server_error","request_id":"req-1"}`}, exitServer},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cp := newSiteCP(t)
			cp.deployResp = fakeResp{200, `{"deployment":{"id":"dep-1","status":"queued","stage":"PLAN","build_id":"b-1","stages":[]}}`}
			cp.pollResp = fakeResp{200, deferred}
			cp.listResp = tc.resp
			cp.serve()
			_, stderr, code := runSite(t, "table", "deploy", testSiteID, "--wait-for-live", "5m")
			if cp.listHits == 0 {
				t.Fatalf("the list route was never hit — the fixture never reached the arm under test\n%s", stderr)
			}
			if code != tc.want {
				t.Fatalf("a %s wait-for-live list refusal must exit %d (%s), got %d (%s)\n%s",
					tc.name, tc.want, siteExitName(tc.want), code, siteExitName(code), stderr)
			}
		})
	}
}

// TestSiteStageTimestampsReachTheJSONEnvelope closes the fourth silent drop, and
// the one that cost a live proof: `SiteStage` has carried `started_at` /
// `finished_at` since the six-stage bar shipped, `GET /v1/sites/:id/deployments/:dep_id`
// emits both per stage (`Sites.Deploy.stages/1` folds them off each console
// entry's `at`), and `siteDeploymentMap` built every row as {name,status,detail}
// and threw them away. `deploy/site-spawner-live-proof.sh`'s `stage_status_ms`
// reads exactly those two keys off `deployment.stages[]`, so the --prebuilt
// journey's step 6/6 compared 0ms against 0ms and red 52 PREBUILT_BUILD_NO_TIMINGS
// on every run — not because the two builds took the same time, but because the
// envelope it parses could not contain a duration at all.
//
// The input is the WIRE, decoded: a real `{"deployment":{…}}` body through
// json.Unmarshal, so this fails if either the struct tags or the map drop them.
//
// MUTATION PROOF: delete either `if st.StartedAt != ""` block in siteDeploymentMap
// and this test reds on the missing key; drop the `!= ""` guard and it reds on
// the never-ran stage carrying a zero time.
func TestSiteStageTimestampsReachTheJSONEnvelope(t *testing.T) {
	// PLAN ran and finished; BUILD ran for 38.4s; STAGE is still running (started,
	// never finished); RETIRE never ran at all and is not on the wire.
	body := []byte(`{"deployment":{
	  "id":"dep-ts","status":"live","stage":"SWITCH","build_id":"b-1",
	  "stages":[
	    {"name":"PLAN","status":"done","started_at":"2026-09-02T10:00:00Z","finished_at":"2026-09-02T10:00:01Z"},
	    {"name":"BUILD","status":"done","started_at":"2026-09-02T10:00:01Z","finished_at":"2026-09-02T10:00:39.4Z","detail":"npm ci && npm run build"},
	    {"name":"STAGE","status":"running","started_at":"2026-09-02T10:00:39.4Z"}
	  ]}}`)
	var wire struct {
		Deployment cloudclient.SiteDeployment `json:"deployment"`
	}
	if err := json.Unmarshal(body, &wire); err != nil {
		t.Fatalf("decode the control plane's own body: %v", err)
	}
	if wire.Deployment.Stages[1].StartedAt == "" || wire.Deployment.Stages[1].FinishedAt == "" {
		t.Fatalf("SiteStage must decode both timestamps off the wire: %+v", wire.Deployment.Stages[1])
	}

	m := siteDeploymentMap(wire.Deployment)
	rows, ok := m["stages"].([]map[string]any)
	if !ok {
		t.Fatalf("stages must be a row list: %+v", m["stages"])
	}
	by := map[string]map[string]any{}
	for _, r := range rows {
		by[fmt.Sprint(r["name"])] = r
	}

	// The BUILD row is the oracle's own input: both keys, RFC3339, verbatim.
	build := by["BUILD"]
	if got := build["started_at"]; got != "2026-09-02T10:00:01Z" {
		t.Fatalf("BUILD started_at = %v, want the control plane's own string: %+v", got, build)
	}
	if got := build["finished_at"]; got != "2026-09-02T10:00:39.4Z" {
		t.Fatalf("BUILD finished_at = %v, want the control plane's own string: %+v", got, build)
	}
	// …and it must survive the marshal the journey actually parses.
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(b), `"finished_at":"2026-09-02T10:00:39.4Z"`) {
		t.Fatalf("the rendered envelope must carry the BUILD finish:\n%s", b)
	}

	// THE ORACLE, computed exactly as stage_status_ms does: a real duration, not 0.
	start, err := time.Parse(time.RFC3339, fmt.Sprint(build["started_at"]))
	if err != nil {
		t.Fatalf("started_at must parse as RFC3339: %v", err)
	}
	end, err := time.Parse(time.RFC3339, fmt.Sprint(build["finished_at"]))
	if err != nil {
		t.Fatalf("finished_at must parse as RFC3339: %v", err)
	}
	if ms := end.Sub(start).Milliseconds(); ms != 38400 {
		t.Fatalf("the BUILD duration the journey reads = %dms, want 38400 — a 0 here IS exit 52", ms)
	}

	// A stage still RUNNING has a start and no finish. The finish key is absent,
	// never a zero time: `stage_status_ms` treats a missing end as 0ms, which is
	// the honest answer for a stage that has not ended, and a fabricated end
	// would report a duration nobody measured.
	stage := by["STAGE"]
	if got := stage["started_at"]; got != "2026-09-02T10:00:39.4Z" {
		t.Fatalf("a running stage keeps its start, got %v: %+v", got, stage)
	}
	if _, ok := stage["finished_at"]; ok {
		t.Fatalf("a running stage must carry NO finish key: %+v", stage)
	}

	// A stage that never ran — synthesized `pending` by siteStagesInOrder off a
	// lean payload — omits BOTH keys. A zero time here would render as
	// "0001-01-01T00:00:00Z" and any reader differencing two of them gets a
	// duration in millennia.
	for _, name := range []string{"HEALTH", "SWITCH", "RETIRE"} {
		row := by[name]
		if row["status"] != "pending" {
			t.Fatalf("%s should be the synthesized pending row: %+v", name, row)
		}
		if _, ok := row["started_at"]; ok {
			t.Fatalf("%s never ran and must carry no started_at: %+v", name, row)
		}
		if _, ok := row["finished_at"]; ok {
			t.Fatalf("%s never ran and must carry no finished_at: %+v", name, row)
		}
	}
}
