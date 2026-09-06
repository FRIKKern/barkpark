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
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
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
	query  string
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
		rec := scriptedRequest{method: r.Method, path: r.URL.Path, query: r.URL.RawQuery, auth: r.Header.Get("Authorization")}
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

// sitesListFixture is the /v1/sites body the list tests read: two sites, one
// carrying the server's `last_deployment` embed (status/trigger/inserted_at/
// updated_at — the four keys router.ex actually sends, and no more), one with
// no embed and no current_deployment_id, i.e. genuinely never deployed.
//
// The deployments routes are DELIBERATELY ABSENT from these fixtures. Before
// deploy-reliability W17 the list walked an N+1 over /v1/sites/:id/deployments
// and would have needed them; now a request to one of those paths 404s through
// the harness and the assertions below catch it by counting requests.
const sitesListFixture = `{"sites":[
	{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"dep-a","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z","last_deployment":{"status":"live","trigger":"content-auto","inserted_at":"2026-06-26T02:00:00Z","updated_at":"2026-06-26T02:04:00Z"}},
	{"id":"site-2","barkpark_id":"bp-1","team_id":"team-1","name":"Shop","slug":"shop","framework":"nextjs","domains":[],"scale_mode":"zero","port":0,"current_deployment_id":"","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z","last_deployment":null}
]}`

// TestSitesListRendersTable: `bp sites` with two sites, one carrying the
// server's last_deployment embed. The table carries NAME, DOMAINS, STATUS,
// LAST DEPLOY.
func TestSitesListRendersTable(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesListFixture)

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
	// Both sites appear, and site-1's status + stamp came off the EMBED (the
	// timestamp is the discriminator: it exists nowhere but last_deployment).
	for _, want := range []string{"Blog", "Shop", "blog.example.com", "live", "2026-06-26T02:00:00Z"} {
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

// TestSitesListReadsTheEmbedAndMakesExactlyOneRequest is the N+1 headstone.
//
// `bp sites` used to issue 1 + N requests — one list, then one
// /v1/sites/:id/deployments per site. Two things were wrong with that, and the
// second is the one this epic cares about: it cost N extra round trips, and it
// read every site's status at a DIFFERENT INSTANT, so the fleet "snapshot" was
// N snapshots stapled together. This pins the request COUNT at exactly one, so
// the walk cannot creep back in unnoticed.
func TestSitesListReadsTheEmbedAndMakesExactlyOneRequest(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesListFixture)

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
	if len(s.requests) != 1 {
		t.Fatalf("bp sites made %d requests, want exactly 1 (the N+1 is back):\n%+v", len(s.requests), s.requests)
	}
	if s.requests[0].path != "/v1/sites" {
		t.Fatalf("the one request was %s %s, want GET /v1/sites", s.requests[0].method, s.requests[0].path)
	}
	// And the outcome still reached the human off that single response.
	if !strings.Contains(stdout, "site outcomes") {
		t.Fatalf("no cohort line rendered:\n%s", stdout)
	}
}

// TestSitesListCohortSplitsSettledFromInFlight: deferred and building are
// reported as IN FLIGHT, never as outcomes, and never-deployed is its own
// named bucket rather than an absence.
//
// The measured reason for the split: two identical calls to the live control
// plane five minutes apart returned {live 8, failed 2, deferred 1, building 1}
// and {live 10, failed 2}, and a 48-hour replay at 30-minute cutoffs produced
// 22 distinct (live, failed, deferred) triples over 97 samples — the modal one
// held only 19.6% of the time. `deferred` and `building` are TRANSIENT states
// that a latest-per-site query happily reports as if they were outcomes.
func TestSitesListCohortSplitsSettledFromInFlight(t *testing.T) {
	withTempConfigHome(t)
	body := `{"sites":[
		{"id":"s1","name":"a","slug":"a","domains":[],"current_deployment_id":"d1","last_deployment":{"status":"live","trigger":"manual","inserted_at":"2026-08-07T10:00:00Z","updated_at":"2026-08-07T10:05:00Z"}},
		{"id":"s2","name":"b","slug":"b","domains":[],"current_deployment_id":"d2","last_deployment":{"status":"failed","trigger":"push","inserted_at":"2026-08-07T10:01:00Z","updated_at":"2026-08-07T10:06:00Z"}},
		{"id":"s3","name":"c","slug":"c","domains":[],"current_deployment_id":"d3","last_deployment":{"status":"deferred","trigger":"content-auto","inserted_at":"2026-08-07T10:02:00Z","updated_at":"2026-08-07T10:02:00Z"}},
		{"id":"s4","name":"d","slug":"d","domains":[],"current_deployment_id":"d4","last_deployment":{"status":"building","trigger":null,"inserted_at":"2026-08-07T10:03:00Z","updated_at":"2026-08-07T10:03:00Z"}},
		{"id":"s5","name":"auto-proof","slug":"auto-proof","domains":[],"current_deployment_id":"","last_deployment":null}
	]}`
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, body)
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
	for _, want := range []string{
		"2 settled — 1 live, 1 failed", // deferred + building are NOT in here
		"2 in flight — 1 deferred, 1 building",
		"1 never deployed", // its own bucket, not a silent drop
		"counts, not a rate",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("cohort line missing %q:\n%s", want, stdout)
		}
	}
	// A percentage anywhere on the cohort line would be pinning the weather.
	if strings.Contains(stdout, "%") {
		t.Fatalf("cohort printed a percentage; the cohort is one instant of a moving system:\n%s", stdout)
	}
}

// TestSiteCohortBucketsSumToSiteCount pins the identity
//
//	settled + in_flight + never_deployed (+ unreported) == len(sites)
//
// mirroring the contract internal/cli/cloud_site_cmd.go:2013 states for the
// per-site window. A site that lands in NO bucket is the denominator lie in
// miniature: the reader subtracts the printed counts from the site count and
// gets an unexplained remainder with no name.
//
// NOTE THE SHAPE OF THESE ASSERTIONS: not one of them pins a cohort VALUE.
// The live cohort is time-varying (22 distinct triples over 97 samples), so a
// test that expected 10 live / 2 failed / 0 deferred would be flaky by
// construction — it would be asserting the weather, not the code.
func TestSiteCohortBucketsSumToSiteCount(t *testing.T) {
	statuses := []string{
		"live", "running", "ready", "active",
		"failed", "error",
		"cancelled", "canceled",
		"deferred", "queued", "building", "pushing",
		"quantum_superposition", // a status word the control plane may add tomorrow
		"",                      // embed present, status word absent
	}
	for _, st := range statuses {
		st := st
		t.Run("status="+st, func(t *testing.T) {
			sites := []cloudclient.Site{
				{ID: "deployed", CurrentDeploymentID: "d1", LastDeployment: &cloudclient.SiteDeploymentEmbed{Status: st}},
				{ID: "never", CurrentDeploymentID: ""},           // no production deploy at all
				{ID: "embed-missing", CurrentDeploymentID: "d2"}, // deployed, but no embed
			}
			c := summarizeSiteCohort(sites)
			if c.Sites != len(sites) {
				t.Fatalf("Sites = %d, want %d", c.Sites, len(sites))
			}
			if got := c.Accounted(); got != len(sites) {
				t.Fatalf("buckets accounted for %d sites, want %d (%+v)", got, len(sites), c)
			}
			if c.NeverDeployed != 1 {
				t.Fatalf("never-deployed = %d, want exactly 1 (%+v)", c.NeverDeployed, c)
			}
			// The exact criterion identity, in the sub-case where the control
			// plane reported everything it owed us.
			if c.Unreported == 1 {
				if c.Settled()+c.InFlight()+c.NeverDeployed+c.Unreported != len(sites) {
					t.Fatalf("settled+in_flight+never_deployed+unreported != len(sites) (%+v)", c)
				}
			}
			// Deferred and building never count as outcomes, at any status.
			if c.Outcomes() != c.Live+c.Failed {
				t.Fatalf("Outcomes() folded in something other than live+failed (%+v)", c)
			}
		})
	}
}

// TestSiteCohortDeferredIsCostNotOutcome: a fleet whose every site is deferred
// reports ZERO outcomes and zero live — it must not report "0% failed" or
// "100% deferred" or any other number that reads like reliability.
//
// The measured justification: 1,837 of 2,124 deferred rows are followed by a
// same-site live within one hour, and 0 of 2,124 ever set became_live_at.
// Deferral is terminal for the ROW and usually transient for the SITE, so it is
// a COST — folding it into a reliability rate lies in whichever direction the
// author picked.
func TestSiteCohortDeferredIsCostNotOutcome(t *testing.T) {
	sites := []cloudclient.Site{
		{ID: "s1", CurrentDeploymentID: "d1", LastDeployment: &cloudclient.SiteDeploymentEmbed{Status: "deferred"}},
		{ID: "s2", CurrentDeploymentID: "d2", LastDeployment: &cloudclient.SiteDeploymentEmbed{Status: "deferred"}},
	}
	c := summarizeSiteCohort(sites)
	if c.Deferred != 2 || c.InFlight() != 2 {
		t.Fatalf("deferred sites did not land in flight: %+v", c)
	}
	if c.Outcomes() != 0 || c.Settled() != 0 {
		t.Fatalf("deferral was counted as an outcome: %+v", c)
	}

	out, buf, _ := newTestWriter()
	renderSiteCohort(out, c)
	got := buf.String()
	if strings.Contains(got, "%") {
		t.Fatalf("a rate was printed over a deferral-only cohort:\n%s", got)
	}
	if !strings.Contains(got, "2 in flight — 2 deferred") {
		t.Fatalf("deferral not reported as in-flight cost:\n%s", got)
	}
}

// TestSitesListJSONCarriesTheEmbedKeysetAndTheCohort: `bp sites -o json` emits
// the server's four embed keys verbatim (no CLI-invented key), the cohort with
// every bucket, and NO rate.
func TestSitesListJSONCarriesTheEmbedKeysetAndTheCohort(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesListFixture)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runSites(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	var payload struct {
		Sites []struct {
			ID             string          `json:"id"`
			Outcome        string          `json:"outcome"`
			NeverDeployed  *bool           `json:"never_deployed"`
			LastDeployment *map[string]any `json:"last_deployment"`
		} `json:"sites"`
		Cohort map[string]any `json:"cohort"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	if len(payload.Sites) != 2 {
		t.Fatalf("want 2 sites, got %d", len(payload.Sites))
	}
	// site-1 carries the embed, with EXACTLY the server's four keys.
	last := payload.Sites[0].LastDeployment
	if last == nil {
		t.Fatalf("site-1 lost its last_deployment:\n%s", stdout)
	}
	// SIX keys now: the four display keys plus the CAUSE PAIR the fleet list
	// could not say. The pair is present-and-null on this LIVE row, which is
	// the point — an absent key would say "this CLI is older than the server"
	// rather than "this deploy succeeded".
	if len(*last) != 6 {
		t.Fatalf("last_deployment widened past the server's keyset: %+v", *last)
	}
	for _, k := range []string{
		"status", "trigger", "inserted_at", "updated_at", "failure_class", "failure_reason",
	} {
		if _, ok := (*last)[k]; !ok {
			t.Fatalf("last_deployment missing %q: %+v", k, *last)
		}
	}
	if payload.Sites[0].Outcome != "live" {
		t.Fatalf("site-1 outcome = %q, want live", payload.Sites[0].Outcome)
	}
	// site-2 has no embed, and says WHICH absence that is.
	if payload.Sites[1].LastDeployment != nil {
		t.Fatalf("site-2 invented a last_deployment: %+v", payload.Sites[1])
	}
	if payload.Sites[1].NeverDeployed == nil || !*payload.Sites[1].NeverDeployed {
		t.Fatalf("site-2 did not report never_deployed=true: %+v", payload.Sites[1])
	}
	if payload.Sites[1].Outcome != "never_deployed" {
		t.Fatalf("site-2 outcome = %q, want never_deployed", payload.Sites[1].Outcome)
	}
	// The cohort rides along, with every bucket named and no rate.
	for _, k := range []string{"sites", "settled", "live", "failed", "in_flight", "deferred", "building", "never_deployed", "unreported", "accounted"} {
		if _, ok := payload.Cohort[k]; !ok {
			t.Fatalf("cohort missing %q: %+v", k, payload.Cohort)
		}
	}
	if payload.Cohort["rate"] != nil {
		t.Fatalf("cohort emitted a rate: %+v", payload.Cohort)
	}
	if payload.Cohort["accounted"] != payload.Cohort["sites"] {
		t.Fatalf("cohort buckets do not account for every site: %+v", payload.Cohort)
	}
}

// TestSitesListYAMLParity: `bp sites -o yaml` must emit the SAME structured
// payload as -o json (a `sites:` list), not silently fall through to the human
// table. Guards the -o yaml format-parity fix for the sites family.
func TestSitesListYAMLParity(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "yaml"
		return runSites(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	// YAML keys present …
	for _, want := range []string{"sites:", "name: Blog", "slug: blog"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("yaml output missing %q:\n%s", want, stdout)
		}
	}
	// … and the human table header must NOT appear (proves no silent downgrade).
	if strings.Contains(stdout, "LAST DEPLOY") {
		t.Fatalf("yaml path leaked the human table header:\n%s", stdout)
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

// TestDeployWithNoSourceRefusesByName: with neither --artifact-url nor --git-ref,
// `bp deploy` REFUSES and names `bp cloud site deploy <site> --prebuilt ./dist`.
//
// site-spawner W10. This replaces TestDeployTarballsCwdByDefault, and that test's
// FIXTURE is the reason the live breakage was invisible: it scripted the artifact
// route as returning `{"artifact_url":…,"filename":…}` — a shape the real route
// STOPPED EMITTING in W9, when the sink moved to Postgres and the `file://` plane
// was retired. From then on the CLI was reading `up.ArtifactURL` off a body that
// no longer carried it, posting an EMPTY artifact_url onto /deploy, and the suite
// stayed green because the fake still said what the server used to. A fake that
// is allowed to drift from its server does not test the server, it tests itself.
//
// The upload is gone now, so the assertion is the negative one: ZERO artifact
// POSTs and ZERO deploy POSTs. A refusal that still reached the wire would be a
// deploy nobody asked for.
func TestDeployWithNoSourceRefusesByName(t *testing.T) {
	withTempConfigHome(t)

	tmp := t.TempDir()
	if err := writeFile(tmp+"/index.js", []byte("console.log('hi')\n")); err != nil {
		t.Fatal(err)
	}

	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}
		]}`)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDeploy(out, []string{"blog", "--dir", tmp})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (usage)", code, exitUsage)
	}

	// Named by name — the replacement verb, with the site the user already typed.
	for _, want := range []string{
		"bp cloud site deploy blog --prebuilt ./dist",
		"--artifact-url",
		"--git-ref",
		"--dir only ever chose which directory to tarball",
	} {
		if !strings.Contains(stderr, want) {
			t.Fatalf("refusal must mention %q:\n%s", want, stderr)
		}
	}

	// ZERO artifact POSTs and ZERO deploy POSTs — the refusal never reaches the
	// wire at all (it precedes even the site resolve).
	if n := len(s.requestsFor("POST", "/v1/sites/site-1/artifact")); n != 0 {
		t.Fatalf("expected ZERO artifact POSTs, got %d", n)
	}
	if n := len(s.requestsFor("POST", "/v1/sites/site-1/deploy")); n != 0 {
		t.Fatalf("expected ZERO deploy POSTs, got %d", n)
	}
	if len(s.requests) != 0 {
		t.Fatalf("a usage error must not hit the wire; got %d requests", len(s.requests))
	}
}

// TestDeployHelpDoesNotAdvertiseTheRetiredFlow: `bp deploy -h` must not promise
// the tar+gzip upload or the `file://` artifact plane, both retired. A help text
// that still describes a deleted flow is worse than no help — the user follows it
// and gets a refusal.
func TestDeployHelpDoesNotAdvertiseTheRetiredFlow(t *testing.T) {
	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runDeploy(out, []string{"--help"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, gone := range []string{"tar+gzip", "file://", "heroku moment", "--dir"} {
		if strings.Contains(stdout, gone) {
			t.Fatalf("help still advertises the retired flow (%q):\n%s", gone, stdout)
		}
	}
	if !strings.Contains(stdout, "--prebuilt ./dist") {
		t.Fatalf("help must point at the prebuilt lane:\n%s", stdout)
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
	for _, want := range []string{"STATUS", "CAUSE", "TRIGGER", "STARTED", "live", "failed"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("deployments table missing %q:\n%s", want, stdout)
		}
	}
}

// deploymentsFixture builds a `{"deployments":[...]}` body with the given mix.
// The rows are stamped an hour apart ascending so the window edges are
// predictable, and returned newest-first the way the control plane returns them.
func deploymentsFixture(live, failed, deferred int) string {
	type row struct{ status, class string }
	var rows []row
	for i := 0; i < live; i++ {
		rows = append(rows, row{"live", ""})
	}
	for i := 0; i < failed; i++ {
		rows = append(rows, row{"failed", "BUILD_FAILED"})
	}
	for i := 0; i < deferred; i++ {
		rows = append(rows, row{"failed", "BOX_AT_CAPACITY_DEFERRED"})
	}
	var b strings.Builder
	b.WriteString(`{"deployments":[`)
	for i, r := range rows {
		if i > 0 {
			b.WriteString(",")
		}
		// Newest first: row 0 gets the LATEST timestamp.
		ts := fmt.Sprintf("2026-08-%02dT00:00:00Z", 28-((len(rows)-1-i)%28))
		b.WriteString(fmt.Sprintf(
			`{"id":"dep-%d","site_id":"site-1","status":%q,"trigger":"push","inserted_at":%q`,
			i, r.status, ts))
		if r.class != "" {
			b.WriteString(fmt.Sprintf(`,"failure_class":%q,"failure_reason":"detail %d"`, r.class, i))
		}
		b.WriteString("}")
	}
	b.WriteString(`]}`)
	return b.String()
}

// runDeploymentsFixture wires a scripted control plane serving `body` and runs
// `bp sites deployments blog <extraArgs...>` in table mode.
func runDeploymentsFixture(t *testing.T, body string, extraArgs ...string) (*scriptedCloud, string, int) {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, body)
	srv := httptest.NewServer(s.handler())
	t.Cleanup(srv.Close)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, append([]string{"deployments", "blog"}, extraArgs...))
	})
	return s, stdout, code
}

// TestSitesDeploymentsTableCarriesCause: deploy-reliability W9. The old table's
// IMAGE_TAG and GIT_REF columns are "—" on every guerrilla row, so three of four
// columns carried nothing. The table now leads with the row's NAMED cause, and a
// key the control plane never sent renders as an explicit dash — never a blank
// cell, which reads as a measured empty value.
func TestSitesDeploymentsTableCarriesCause(t *testing.T) {
	body := `{"deployments":[
		{"id":"dep-3","site_id":"site-1","status":"failed","failure_class":"BOX_AT_CAPACITY_DEFERRED","failure_reason":"box full","trigger":"push","stage":"queue","inserted_at":"2026-08-07T03:00:00Z"},
		{"id":"dep-2","site_id":"site-1","status":"failed","failure_class":"BUILD_FAILED","trigger":"manual","inserted_at":"2026-08-07T02:00:00Z"},
		{"id":"dep-1","site_id":"site-1","status":"live","inserted_at":"2026-08-07T01:00:00Z"}
	]}`
	_, stdout, code := runDeploymentsFixture(t, body)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	lines := strings.Split(strings.TrimRight(stdout, "\n"), "\n")
	// Two summary lines, one blank, then the header and three rows.
	if len(lines) != 7 {
		t.Fatalf("want 7 output lines, got %d:\n%s", len(lines), stdout)
	}
	header := lines[3]
	for _, gone := range []string{"IMAGE_TAG", "GIT_REF"} {
		if strings.Contains(header, gone) {
			t.Fatalf("header still carries the causeless column %q: %q", gone, header)
		}
	}
	if !strings.HasPrefix(header, "STATUS  CAUSE") || !strings.Contains(header, "TRIGGER") || !strings.HasSuffix(header, "STARTED") {
		t.Fatalf("header = %q, want STATUS · CAUSE · TRIGGER · STARTED", header)
	}
	if !strings.Contains(lines[4], "BOX_AT_CAPACITY_DEFERRED") || !strings.Contains(lines[5], "BUILD_FAILED") {
		t.Fatalf("cause column missing its classes:\n%s", stdout)
	}
	// The live row sent neither failure_class nor trigger: BOTH must be dashes.
	live := lines[6]
	if strings.Count(live, "—") != 2 {
		t.Fatalf("the live row must render two explicit dashes (no cause, no trigger), got %q", live)
	}
	// Columns must still line up: the em dash is multi-byte, and byte-width
	// padding would shear the table.
	if strings.Index(lines[5], "manual") != strings.Index(header, "TRIGGER") {
		t.Fatalf("TRIGGER column misaligned:\n%s", stdout)
	}
}

// TestSitesDeploymentsSummaryCarriesItsDenominator: the summary line prints its
// counts and BOTH rates with the denominator each rate was computed over, on the
// same line, and names the window it was computed from. A bare percentage is
// exactly the mis-report this epic exists to remove.
func TestSitesDeploymentsSummaryCarriesItsDenominator(t *testing.T) {
	_, stdout, code := runDeploymentsFixture(t, deploymentsFixture(20, 3, 77))
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	lines := strings.Split(stdout, "\n")
	wantSummary := "20 live, 3 failed, 77 deferred — 13.0% failed of 23 terminal outcomes, 77.0% of 100 rows never attempted (box deferred them)"
	if lines[0] != wantSummary {
		t.Fatalf("summary line\n got: %q\nwant: %q", lines[0], wantSummary)
	}
	wantWindow := "window: 2026-08-01T00:00:00Z → 2026-08-28T00:00:00Z (100 rows fetched)"
	if lines[1] != wantWindow {
		t.Fatalf("window line\n got: %q\nwant: %q", lines[1], wantWindow)
	}
}

// TestSitesDeploymentsUnmeteredBelowSample: MUTATION proof for the sample floor.
// Four rows cannot support a percentage, so the summary must say UNMETERED and
// carry NO percent sign at all — this assertion fails the moment the floor is
// removed and a "25.0%" over four rows comes back.
func TestSitesDeploymentsUnmeteredBelowSample(t *testing.T) {
	_, stdout, code := runDeploymentsFixture(t, deploymentsFixture(2, 1, 1))
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	summary := strings.Split(stdout, "\n")[0]
	if strings.Contains(summary, "%") {
		t.Fatalf("a 4-row window must not print a percentage at all, got: %q", summary)
	}
	want := "2 live, 1 failed, 1 deferred — failure rate UNMETERED (3 terminal outcomes, need 10), deferral rate UNMETERED (4 rows, need 10)"
	if summary != want {
		t.Fatalf("summary\n got: %q\nwant: %q", summary, want)
	}
}

// TestSitesDeploymentsCancelledAndBareDeferredAreNotMisbucketed is the
// REVIEWER's addition (W9). Two ways the summary could still mis-report:
//
//   - `status:"cancelled"` is a real terminal state in the control plane's
//     Deployment transition map. Falling through to the default arm painted it
//     "in flight" — a row that will never move again, reported as running.
//   - `status:"deferred"` is ALSO a real state, and such a row can arrive
//     without a DEFERRED_* failure_class (a nil reason still classifies, but
//     the CLI must not depend on the class key being the only spelling). A
//     class-only reader counted it as neither an attempt nor a deferral.
//
// Both would inflate/deflate a denominator silently, which is this epic's
// disease. Mutation-checked: dropping either arm from classifyDeployment reds
// this test.
func TestSitesDeploymentsCancelledAndBareDeferredAreNotMisbucketed(t *testing.T) {
	body := `{"deployments":[
		{"id":"dep-4","site_id":"site-1","status":"cancelled","inserted_at":"2026-08-07T04:00:00Z"},
		{"id":"dep-3","site_id":"site-1","status":"deferred","inserted_at":"2026-08-07T03:00:00Z"},
		{"id":"dep-2","site_id":"site-1","status":"failed","failure_class":"BUILD_FAILED","inserted_at":"2026-08-07T02:00:00Z"},
		{"id":"dep-1","site_id":"site-1","status":"live","inserted_at":"2026-08-07T01:00:00Z"}
	]}`
	_, stdout, code := runDeploymentsFixture(t, body)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	summary := strings.Split(stdout, "\n")[0]
	if !strings.HasPrefix(summary, "1 live, 1 failed, 1 deferred, 1 cancelled —") {
		t.Fatalf("counts\n got: %q\nwant the cancelled row in its own bucket and the bare deferred row counted as deferred", summary)
	}
	if strings.Contains(summary, "in flight") {
		t.Fatalf("nothing here is in flight — a cancelled row is stopped, not running: %q", summary)
	}
	// And the terminal denominator stays the two rows that actually decided
	// something about a build.
	if !strings.Contains(summary, "2 terminal outcomes") {
		t.Fatalf("terminal denominator must be 2 (live + failed), got: %q", summary)
	}
}

// TestSitesDeploymentsPagesWithLimitAndCursor: the window is requestable and the
// cursor that reaches past it is PRINTED. Before W9 the call sent no query at
// all and silently took whatever the server's default page was.
func TestSitesDeploymentsPagesWithLimitAndCursor(t *testing.T) {
	body := `{"deployments":[
		{"id":"dep-1","site_id":"site-1","status":"live","trigger":"push","inserted_at":"2026-08-07T01:00:00Z"}
	],"next_cursor":"cur-next"}`
	s, stdout, code := runDeploymentsFixture(t, body, "--limit", "250", "--before", "cur-prev")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	reqs := s.requestsFor("GET", "/v1/sites/site-1/deployments")
	if len(reqs) != 1 || reqs[0].query != "before=cur-prev&limit=250" {
		t.Fatalf("wire query = %+v, want before=cur-prev&limit=250", reqs)
	}
	if !strings.Contains(stdout, "older rows exist — '--before cur-next'") {
		t.Fatalf("a truncated window must say so and name the cursor:\n%s", stdout)
	}
}

// TestSitesDeploymentsRejectsBadLimit: a limit that isn't a positive number is a
// usage error, not a silently-dropped flag that would leave the caller reading a
// window they didn't ask for.
func TestSitesDeploymentsRejectsBadLimit(t *testing.T) {
	withTempConfigHome(t)
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runSites(out, []string{"deployments", "blog", "--limit", "0"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want exitUsage", code)
	}
}

// TestSitesDeploymentsJSONKeepsAbsenceAbsent: -o json still carries image_tag /
// git_ref (nothing was taken away from machines), and a cause key the control
// plane never sent marshals as null — distinguishable from a measured "".
func TestSitesDeploymentsJSONKeepsAbsenceAbsent(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).
		route("GET", "/v1/sites", http.StatusOK, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":[],"scale_mode":"always_on"}
		]}`).
		route("GET", "/v1/sites/site-1/deployments", http.StatusOK, `{"deployments":[
			{"id":"dep-2","site_id":"site-1","status":"failed","failure_class":"BUILD_FAILED","failure_reason":"","image_tag":"sha:bbbb","git_ref":"main","inserted_at":"2026-08-07T02:00:00Z"},
			{"id":"dep-1","site_id":"site-1","status":"live","image_tag":"sha:aaaa","git_ref":"main","inserted_at":"2026-08-07T01:00:00Z"}
		]}`)
	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runSites(out, []string{"deployments", "blog"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	var env struct {
		Deployments []map[string]any `json:"deployments"`
		Summary     map[string]any   `json:"summary"`
		NextCursor  *string          `json:"next_cursor"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	if env.Deployments[0]["image_tag"] != "sha:bbbb" || env.Deployments[0]["git_ref"] != "main" {
		t.Fatalf("json lost image_tag/git_ref: %+v", env.Deployments[0])
	}
	if env.Deployments[0]["failure_class"] != "BUILD_FAILED" {
		t.Fatalf("json lost failure_class: %+v", env.Deployments[0])
	}
	// Sent-but-empty stays "", never-sent stays null. The whole point of the
	// pointer decode is that these two are not the same answer.
	if fr, present := env.Deployments[0]["failure_reason"]; !present || fr != "" {
		t.Fatalf("a measured-empty failure_reason must stay \"\", got %#v", fr)
	}
	if fc := env.Deployments[1]["failure_class"]; fc != nil {
		t.Fatalf("an absent failure_class must marshal null, got %#v", fc)
	}
	if env.NextCursor != nil {
		t.Fatalf("no next_cursor on the wire must be null, got %q", *env.NextCursor)
	}
	// The machine surface carries the same denominators the human line does.
	for _, k := range []string{"rows", "terminal", "deferred", "window_oldest", "window_newest", "min_sample"} {
		if _, ok := env.Summary[k]; !ok {
			t.Fatalf("summary missing %q: %+v", k, env.Summary)
		}
	}
	if env.Summary["failed_pct"] != nil {
		t.Fatalf("a 2-row window must not carry a failed_pct, got %#v", env.Summary["failed_pct"])
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

// TestCloudSiteLsAliasesTeamList (dr-w14-bl-owner-cannot-list-own-sites): the
// wave-14 verifier, standing at the `bp cloud site` noun, got `unknown site
// command "ls"` and had to curl /v1/sites to find their own 13 sites — while
// `bp sites` answered the question all along. The ruling is ALIASING: `bp
// cloud site ls` routes to the same team list, so an owner at either noun can
// enumerate, and the output names each site's SLUG — the handle every other
// verb takes.
func TestCloudSiteLsAliasesTeamList(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesListFixture)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudSite(out, globals{}, []string{"ls"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	// The SLUG column and both slugs render — an owner can act on what they see.
	for _, want := range []string{"SLUG", "blog", "shop"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("cloud site ls output missing %q:\n%s", want, stdout)
		}
	}
	if len(s.requestsFor("GET", "/v1/sites")) != 1 {
		t.Fatalf("expected exactly one /v1/sites read; requests = %+v", s.requests)
	}
}

// TestCloudSiteUnknownVerbNamesTheListingPath: the refusal that used to strand
// the owner now names both listing verbs.
func TestCloudSiteUnknownVerbNamesTheListingPath(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudSite(out, globals{}, []string{"enumerate"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want usage", code)
	}
	if !strings.Contains(stderr, "bp sites") || !strings.Contains(stderr, "bp cloud site ls") {
		t.Fatalf("the unknown-verb refusal must name the listing path:\n%s", stderr)
	}
}

// sitesListFailureFixture: one site whose last production deploy FAILED and
// carries the control plane's cause pair, one that is live (explicit nulls on
// both cause keys — the server's own way of saying "no cause here"), and one
// that never deployed. The fleet list is the only surface that shows all three
// at once, which is exactly why the cause has to reach it.
const sitesListFailureFixture = `{"sites":[
	{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"dep-a","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z","last_deployment":{"status":"failed","trigger":"manual","inserted_at":"2026-06-26T02:00:00Z","updated_at":"2026-06-26T02:04:00Z","failure_class":"BOX_BUSY_409","failure_reason":"the instance refused the deploy (HTTP 409): already_running"}},
	{"id":"site-2","barkpark_id":"bp-1","team_id":"team-1","name":"Shop","slug":"shop","framework":"nextjs","domains":[],"scale_mode":"zero","port":0,"current_deployment_id":"dep-b","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z","last_deployment":{"status":"live","trigger":"content-auto","inserted_at":"2026-06-26T03:00:00Z","updated_at":"2026-06-26T03:04:00Z","failure_class":null,"failure_reason":null}},
	{"id":"site-3","barkpark_id":"bp-1","team_id":"team-1","name":"Docs","slug":"docs","framework":"nextjs","domains":[],"scale_mode":"zero","port":0,"current_deployment_id":"","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z","last_deployment":null}
]}`

func sitesTableFor(t *testing.T, fixture string) string {
	t.Helper()
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, fixture)

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
	return stdout
}

// TestSitesListNamesTheFailureCause: `bp sites` could say THAT a site's last
// deploy failed and never WHY — the Go struct dropped the two keys the API
// projects. The table now carries a WHY column with the class AND the
// humanized sentence, both taken verbatim off the wire.
func TestSitesListNamesTheFailureCause(t *testing.T) {
	stdout := sitesTableFor(t, sitesListFailureFixture)

	for _, want := range []string{
		"WHY",
		"BOX_BUSY_409",
		"the instance refused the deploy (HTTP 409): already_running",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing %q:\n%s", want, stdout)
		}
	}
	// The LIVE site does not borrow the failed site's cause. Its row is
	// identified by its own slug so this cannot pass on a substring of the
	// failed row.
	for _, line := range strings.Split(stdout, "\n") {
		if !strings.Contains(line, "shop") {
			continue
		}
		if strings.Contains(line, "BOX_BUSY_409") || strings.Contains(line, "refused") {
			t.Fatalf("live site borrowed a cause:\n%s", line)
		}
	}
}

// TestSitesListOmitsWhyWhenNothingFailed: the WHY column is CONDITIONAL. A
// fleet with no cause to name gets the table it always had — a column of "—"
// would imply the CLI lost something the server sent.
func TestSitesListOmitsWhyWhenNothingFailed(t *testing.T) {
	stdout := sitesTableFor(t, sitesListFixture)

	if strings.Contains(stdout, "WHY") {
		t.Fatalf("WHY column appeared with nothing to explain:\n%s", stdout)
	}
	// …and the columns that were always there still are.
	for _, want := range []string{"NAME", "SLUG", "DOMAINS", "STATUS", "LAST DEPLOY"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table missing column %q:\n%s", want, stdout)
		}
	}
}

// TestSitesListJSONCarriesTheCausePair: `-o json` re-emits the server's cause
// pair, and emits EXPLICIT NULLS on a row that did not fail. A missing key and
// a null key are different facts — the first says "this CLI is older than the
// server", the second says "this deploy succeeded" — and a consumer must be
// able to tell them apart from the payload alone.
func TestSitesListJSONCarriesTheCausePair(t *testing.T) {
	withTempConfigHome(t)
	s := newScriptedCloud(t).route("GET", "/v1/sites", http.StatusOK, sitesListFailureFixture)

	srv := httptest.NewServer(s.handler())
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "json"
		return runSites(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}

	var payload struct {
		Sites []struct {
			Slug           string `json:"slug"`
			LastDeployment *struct {
				Status        string  `json:"status"`
				FailureClass  *string `json:"failure_class"`
				FailureReason *string `json:"failure_reason"`
			} `json:"last_deployment"`
		} `json:"sites"`
	}
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}

	byslug := map[string]*string{}
	rawKeys := map[string]bool{}
	for _, site := range payload.Sites {
		if site.LastDeployment == nil {
			continue
		}
		byslug[site.Slug] = site.LastDeployment.FailureClass
		rawKeys[site.Slug] = true
	}

	if got := byslug["blog"]; got == nil || *got != "BOX_BUSY_409" {
		t.Fatalf("blog failure_class = %v, want BOX_BUSY_409", got)
	}
	if got := byslug["shop"]; got != nil {
		t.Fatalf("live site carries a failure_class %q", *got)
	}

	// The KEY is present on the live row, not merely null-by-absence. Decoded
	// pointers cannot tell those apart, so read the raw map.
	var raw struct {
		Sites []map[string]any `json:"sites"`
	}
	if err := json.Unmarshal([]byte(stdout), &raw); err != nil {
		t.Fatalf("decode raw: %v", err)
	}
	for _, site := range raw.Sites {
		if site["slug"] != "shop" {
			continue
		}
		last, ok := site["last_deployment"].(map[string]any)
		if !ok {
			t.Fatalf("shop has no last_deployment object: %v", site)
		}
		for _, k := range []string{"failure_class", "failure_reason"} {
			v, present := last[k]
			if !present {
				t.Fatalf("live row omits %q entirely — an absent key says the CLI is stale, not that the deploy succeeded", k)
			}
			if v != nil {
				t.Fatalf("live row %q = %v, want null", k, v)
			}
		}
		// And nothing widened the embed while we were here.
		for _, forbidden := range []string{"failure_reason_raw", "console", "build_log_url", "content_rev"} {
			if _, present := last[forbidden]; present {
				t.Fatalf("embed leaked %q", forbidden)
			}
		}
	}
}
