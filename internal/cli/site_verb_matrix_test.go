package cli

// site_verb_matrix_test.go — the two arms the unification ships with.
//
// RED-WHEN-REVERTED (TestSiteVerbsResolveIdenticallyAtBothSpellings,
// TestSiteSharedVerbsAreOneFuncValue): every shared verb must be reachable at
// BOTH nouns and must reach the SAME func value. Give `bp sites` its own switch
// back, or drop a verb from one noun, and these red.
//
// QUIET-WHEN-CORRECT (TestSiteSharedVerbsSameURLAndOutputAtBothSpellings): each
// shared verb is run through BOTH spellings against ONE recording server, and
// the recorded request sequence, the stdout and the exit code must match byte
// for byte. That is the regression the row warned about — a unification that
// silently changes a verb's URL, its default flags or its output shape. It
// stays quiet as long as the aliasing is a pure rename of the door.
//
// KIND DIFFERENCES ARE ASSERTED, NOT ALIASED AWAY
// (TestSiteCreateStaysSpellingBound, TestSitesDeployRefusesAndNamesBothDoors):
// `create` builds a DIFFERENT request body at each noun and `bp sites deploy`
// refuses by naming both doors, so neither is quietly folded into the other.

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// matrixSiteID is the id every fixture below uses. It is a UUID so the `<site>`
// resolver takes the id path and not the ListSites slug walk — which keeps the
// recorded request sequences short and the comparison about the verb.
const matrixSiteID = "11111111-2222-3333-4444-555555555555"

// --- arm 1: both nouns, one func value ---------------------------------------

// Every shared verb must resolve at both spellings. A verb that answers at one
// noun and refuses at the other is exactly the defect the matrix retired.
func TestSiteVerbsResolveIdenticallyAtBothSpellings(t *testing.T) {
	shared := 0
	for _, b := range siteVerbMatrix {
		if b.Scope != siteVerbShared {
			continue
		}
		shared++
		for _, name := range b.names() {
			got, ok := lookupSiteVerb(name)
			if !ok {
				t.Fatalf("%q is in siteVerbMatrix but lookupSiteVerb refuses it", name)
			}
			if got.handler(siteSpellingFleet) == nil {
				t.Errorf("shared verb %q is not offered at `bp sites`", name)
			}
			if got.handler(siteSpellingSpawner) == nil {
				t.Errorf("shared verb %q is not offered at `bp cloud site`", name)
			}
		}
	}
	// Non-vacuity floor: before the unification only `ls` was shared. A table
	// that has collapsed back to a handful means the reader, not the tree, is
	// what changed.
	if shared < 12 {
		t.Fatalf("only %d shared verbs in siteVerbMatrix — the unification regressed "+
			"(or this floor is reading the wrong table)", shared)
	}
}

// The two spellings must reach ONE func value, not two copies. Split a shared
// row into Fleet+Spawner and this reds even if both halves still work today —
// which is the point: two implementations are two things that can drift.
func TestSiteSharedVerbsAreOneFuncValue(t *testing.T) {
	for _, b := range siteVerbMatrix {
		if b.Scope != siteVerbShared {
			continue
		}
		fleet := reflect.ValueOf(b.handler(siteSpellingFleet)).Pointer()
		spawner := reflect.ValueOf(b.handler(siteSpellingSpawner)).Pointer()
		if fleet != spawner {
			t.Errorf("shared verb %q reaches %s at `bp sites` and %s at `bp cloud site` — "+
				"two implementations, not one", b.Verb,
				runtime.FuncForPC(fleet).Name(), runtime.FuncForPC(spawner).Name())
		}
		if b.Fleet != nil || b.Spawner != nil {
			t.Errorf("shared verb %q sets Fleet/Spawner — a shared row carries Impl ONLY, "+
				"so the two doors cannot drift", b.Verb)
		}
	}
}

// --- arm 2: same URL, same bytes, same exit ----------------------------------

// matrixCloud is a recording fake control plane answering the read routes the
// shared verbs walk. Every request is recorded as "METHOD path?query" so two
// runs can be compared as sequences.
type matrixCloud struct {
	t *testing.T
	// site is the fixture kind this server answers with — the parity loop runs
	// the whole shared tree once per kind.
	site string
	log  []string
}

func (m *matrixCloud) reset() { m.log = nil }

func (m *matrixCloud) serve() *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := r.Method + " " + r.URL.Path
		if r.URL.RawQuery != "" {
			rec += "?" + r.URL.RawQuery
		}
		m.log = append(m.log, rec)
		body, status := matrixFixture(m.site, r.Method, r.URL.Path)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	m.t.Cleanup(srv.Close)
	withTempConfigHome(m.t)
	seedCloudLogin(m.t, srv.URL)
	return srv
}

// matrixSiteFixture is ONE site shape the parity loop runs the whole shared
// tree against. The criterion names TWO kinds and they are not decoration: a
// content-bound static site and a BYO-repo container site walk different
// render branches (runtime target, scale mode, the GitHub link, the prebuilt
// opt-in), so a spelling that diverged only on the container branch would be
// invisible to a static-only fixture.
type matrixSiteFixture struct {
	name string
	site string
}

var matrixSiteFixtures = []matrixSiteFixture{
	{
		name: "static-content-bound",
		site: `{"id":"` + matrixSiteID + `","name":"blog","slug":"blog","kind":"static",` +
			`"framework":"astro","runtime_target":"static","domains":["blog.example.com"],` +
			`"prebuilt_enabled":true,"scale_mode":"scale_to_zero","port":0,` +
			`"workspace":"acme","project":"blog","dataset":"production",` +
			`"instance":"box-1","url":"https://box-1.barkpark.cloud/sites/blog/",` +
			`"theme":"evergreen","doc_type":"post","publish_trigger":"present"}`,
	},
	{
		name: "container-byo-repo",
		site: `{"id":"` + matrixSiteID + `","name":"blog","slug":"blog","kind":"container",` +
			`"framework":"nextjs","runtime_target":"node","domains":["app.example.com"],` +
			`"prebuilt_enabled":false,"scale_mode":"always_on","port":3000,` +
			`"github_repo":"acme/blog","github_branch":"main","github_webhook_configured":true,` +
			`"instance":"box-1","url":"https://box-1.barkpark.cloud/sites/blog/"}`,
	},
}

// matrixFixture answers the routes the shared verbs walk for ONE fixture kind.
// The reads are shaped per route; every write gets one generic envelope that
// carries the keys the write receipts read (ok/status/slug/site/deployment
// ids). Fidelity is not the point here — SAMENESS is: the two spellings must
// meet the same server and produce the same bytes, and an identical refusal at
// both nouns is as good a parity measurement as an identical success.
func matrixFixture(site, method, path string) (string, int) {
	switch {
	case method == "GET" && path == "/v1/sites":
		return `{"sites":[` + site + `]}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID+"/deployments":
		return `{"deployments":[],"next_cursor":null}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID+"/doctor":
		return `{"report":{"site_id":"` + matrixSiteID + `","substrates":[]}}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID:
		return `{"site":` + site + `}`, http.StatusOK
	case method == "GET":
		return `{"error":"not_found"}`, http.StatusNotFound
	}
	return `{"ok":true,"status":"deleted","slug":"blog","deployment_id":"dep-2",` +
		`"previous_deployment_id":"dep-1","url":"https://box-1.barkpark.cloud/sites/blog/",` +
		`"site":` + site + `}`, http.StatusOK
}

// runAtSpelling drives one verb through one spelling with a fresh writer and
// the SAME globals at both nouns. `g` is threaded rather than hardcoded: `bp
// sites` used to hand the shared handler a zero `globals{}` while `bp cloud
// site` handed it the real one, so `bp --yes sites delete <site>` prompted at a
// TTY where `bp --yes cloud site delete <site>` did not — a behavioural
// difference between two spellings that are meant to be one implementation.
func runAtSpelling(t *testing.T, spelling, output string, g globals, argv []string) (string, string, int) {
	t.Helper()
	orig := siteDeployPoll
	siteDeployPoll = 0
	t.Cleanup(func() { siteDeployPoll = orig })
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	var code int
	if spelling == siteSpellingFleet {
		code = runSites(w, g, argv)
	} else {
		code = runCloudSite(w, g, argv)
	}
	return sout.String(), serr.String(), code
}

// siteVerbParityArgs is the TAIL each shared verb needs to reach its work —
// data, not coverage. Coverage is a PREDICATE over siteVerbMatrix: the loop
// below walks every shared row and every alias on it, and a shared verb with no
// entry here FAILS the test by name. A hand-listed case table was the defect
// this replaces — it ran 7 of 15 shared verbs and silently stopped growing, so
// `delete` (the one that actually diverged) was never run at both spellings.
var siteVerbParityArgs = map[string]func(t *testing.T) []string{
	"ls":          func(*testing.T) []string { return nil },
	"show":        func(*testing.T) []string { return []string{matrixSiteID} },
	"deployments": func(*testing.T) []string { return []string{matrixSiteID} },
	"status":      func(*testing.T) []string { return []string{matrixSiteID} },
	"doctor":      func(*testing.T) []string { return []string{matrixSiteID} },
	"rollback":    func(*testing.T) []string { return []string{matrixSiteID} },
	"delete":      func(*testing.T) []string { return []string{matrixSiteID} },
	"open":        func(*testing.T) []string { return []string{matrixSiteID, "--print-only"} },
	"settings":    func(*testing.T) []string { return []string{matrixSiteID, "--theme", "fjord"} },
	"logs":        func(*testing.T) []string { return []string{matrixSiteID} },
	"matrix":      func(*testing.T) []string { return nil },
	"env":         func(*testing.T) []string { return []string{"set", matrixSiteID, "FOO=bar"} },
	"domain":      func(*testing.T) []string { return []string{"add", matrixSiteID, "www.example.com"} },
	"github":      func(*testing.T) []string { return []string{"connect", matrixSiteID, "--repo", "acme/blog"} },
	"preflight": func(t *testing.T) []string {
		return []string{"--dir", t.TempDir(), "--skip-build"}
	},
}

// siteSharedParityNames is the PREDICATE: every name (canonical + alias) on
// every shared row of siteVerbMatrix, paired with the tail that reaches its
// work. Add a shared verb to the matrix and it is covered here without editing
// the loop; add one with no args entry and the test names it rather than
// quietly skipping it.
func siteSharedParityNames(t *testing.T) []struct {
	verb string
	name string
	args func(t *testing.T) []string
} {
	t.Helper()
	var out []struct {
		verb string
		name string
		args func(t *testing.T) []string
	}
	for _, b := range siteVerbMatrix {
		if b.Scope != siteVerbShared {
			continue
		}
		mk, ok := siteVerbParityArgs[b.Verb]
		if !ok {
			t.Fatalf("shared verb %q has no siteVerbParityArgs entry — a shared verb that no "+
				"parity case runs is exactly the hole this loop replaced; add its argument tail",
				b.Verb)
		}
		for _, n := range b.names() {
			out = append(out, struct {
				verb string
				name string
				args func(t *testing.T) []string
			}{b.Verb, n, mk})
		}
	}
	return out
}

// THE QUIET ARM. EVERY shared verb (canonical and alias) x BOTH spellings x
// both output modes x both globals x both fixture kinds, against one recording
// server: the request sequence, stdout, stderr and exit code must be identical.
// It says nothing while the aliasing is a pure rename of the door, and names
// the verb the moment one spelling calls a different URL, prints a different
// shape, or — the delete case — receives a different `globals`.
//
// The confirm gate is driven LIVE here (hzStdinIsTTY forced true): under plain
// `go test` stdin is not a terminal, so the destroy prompt skips itself and the
// --yes divergence is invisible. Forcing the TTY seam is what makes the
// globals half of this arm able to fail at all.
func TestSiteSharedVerbsSameURLAndOutputAtBothSpellings(t *testing.T) {
	origTTY := hzStdinIsTTY
	origStdin := hzStdin
	hzStdinIsTTY = func(io.Reader) bool { return true }
	hzStdin = strings.NewReader("")
	t.Cleanup(func() { hzStdinIsTTY = origTTY; hzStdin = origStdin })

	// `preflight` shells out to the two engine self-test harnesses. Point the
	// resolver at paths that do not exist: runOneSelfTest then short-circuits on
	// os.Stat and the verb stays OFFLINE and fast, which is what a parity loop
	// wants — the question here is whether the two spellings print the same
	// bytes, not whether the engine passes its own self-test.
	origFind := findSiteDeployScripts
	findSiteDeployScripts = func() (string, string, error) {
		return "/nonexistent/bp-parity/site-deploy.sh", "/nonexistent/bp-parity/site-deploy-node.sh", nil
	}
	t.Cleanup(func() { findSiteDeployScripts = origFind })

	globalCases := []struct {
		label string
		g     globals
	}{
		{"plain", globals{}},
		// --yes is the global that actually reaches a shared handler's behaviour
		// (`g.yes || a.bools["yes"]` in the destroy gate). Running it proves the
		// two spellings hand the SAME globals to the same func.
		{"yes", globals{yes: true}},
	}

	names := siteSharedParityNames(t)
	// Non-vacuity floor #1: the loop is derived from the table, so an empty or
	// collapsed table would make every assertion below unreachable. Before the
	// unification only `ls` was shared; the matrix carries 15 shared verbs and
	// 21 spellings-of-a-verb counting aliases.
	if len(names) == 0 {
		t.Fatal("siteSharedParityNames returned nothing — the loop is vacuous")
	}
	sharedRows := 0
	for _, b := range siteVerbMatrix {
		if b.Scope == siteVerbShared {
			sharedRows++
		}
	}
	if sharedRows < 15 {
		t.Fatalf("siteVerbMatrix has %d shared rows, want >= 15 — the unification regressed "+
			"(or this floor is reading the wrong table)", sharedRows)
	}
	if len(names) < sharedRows {
		t.Fatalf("parity loop covers %d names for %d shared rows — every row must contribute "+
			"at least its canonical verb", len(names), sharedRows)
	}
	// Non-vacuity floor #2: the criterion names TWO fixture kinds by shape, so
	// the floor asserts the SHAPES, not the slice length — a floor whose expected
	// value is read off the thing it guards (len(matrixSiteFixtures)) is inert.
	// Delete the container fixture and this reds; rename one and it still reds.
	var haveStatic, haveContainer bool
	for _, fx := range matrixSiteFixtures {
		if strings.Contains(fx.site, `"kind":"static"`) && strings.Contains(fx.site, `"dataset"`) {
			haveStatic = true
		}
		if strings.Contains(fx.site, `"kind":"container"`) && strings.Contains(fx.site, `"github_repo"`) {
			haveContainer = true
		}
	}
	if !haveStatic {
		t.Fatal("no static/content-bound fixture in matrixSiteFixtures — the criterion names it by kind")
	}
	if !haveContainer {
		t.Fatal("no container/BYO-repo fixture in matrixSiteFixtures — the criterion names it by kind")
	}

	ran := 0
	for _, fx := range matrixSiteFixtures {
		for _, gc := range globalCases {
			for _, output := range []string{"table", "json"} {
				for _, nc := range names {
					caseName := fx.name + "/" + gc.label + "/" + output + "/" + nc.name
					t.Run(caseName, func(t *testing.T) {
						m := &matrixCloud{t: t, site: fx.site}
						m.serve()
						argv := append([]string{nc.name}, nc.args(t)...)

						m.reset()
						fleetOut, fleetErr, fleetCode := runAtSpelling(t, siteSpellingFleet, output, gc.g, argv)
						fleetReqs := append([]string(nil), m.log...)

						m.reset()
						spawnOut, spawnErr, spawnCode := runAtSpelling(t, siteSpellingSpawner, output, gc.g, argv)
						spawnReqs := append([]string(nil), m.log...)

						if !reflect.DeepEqual(fleetReqs, spawnReqs) {
							t.Errorf("`bp sites %s` and `bp cloud site %s` call DIFFERENT URLs [%s]:\n  sites:      %v\n  cloud site: %v",
								nc.name, nc.name, caseName, fleetReqs, spawnReqs)
						}
						if fleetOut != spawnOut {
							t.Errorf("`bp sites %s` and `bp cloud site %s` print different stdout [%s]:\n--- sites ---\n%s\n--- cloud site ---\n%s",
								nc.name, nc.name, caseName, fleetOut, spawnOut)
						}
						if fleetErr != spawnErr {
							t.Errorf("%s: stderr differs:\n--- sites ---\n%s\n--- cloud site ---\n%s", caseName, fleetErr, spawnErr)
						}
						if fleetCode != spawnCode {
							t.Errorf("%s: exit differs — sites=%d cloud site=%d", caseName, fleetCode, spawnCode)
						}
						// Non-vacuity floor #3, per case: a run that made no
						// request AND printed nothing at either stream compares
						// two nothings.
						if len(fleetReqs) == 0 && fleetOut == "" && fleetErr == "" {
							t.Fatalf("%s made no request and printed nothing — the comparison is vacuous", caseName)
						}
					})
					ran++
				}
			}
		}
	}
	// Non-vacuity floor #4: the generated case count is the product of the four
	// axes the criterion names. A loop that silently generated fewer (a `continue`
	// added, a fixture dropped) is a coverage regression that would otherwise
	// still report PASS.
	want := len(matrixSiteFixtures) * len(globalCases) * 2 * len(names)
	if ran != want {
		t.Fatalf("parity loop ran %d cases, want %d (%d fixtures x %d globals x 2 outputs x %d verb spellings)",
			ran, want, len(matrixSiteFixtures), len(globalCases), len(names))
	}
	t.Logf("parity: %d cases = %d fixture kinds x %d globals x 2 outputs x %d shared verb spellings (%d shared rows)",
		ran, len(matrixSiteFixtures), len(globalCases), len(names), sharedRows)
}

// --- the kind differences that are NOT aliased -------------------------------

// `create` must stay spelling-bound: the two nouns POST the SAME route with
// DIFFERENT bodies (container vs content-bound spawn). Folding them would
// silently change which kind of site a documented script creates.
func TestSiteCreateStaysSpellingBound(t *testing.T) {
	b, ok := lookupSiteVerb("create")
	if !ok {
		t.Fatal("create is not in siteVerbMatrix")
	}
	if b.Scope != siteVerbSplit {
		t.Fatalf("create scope = %q, want %q — the kind difference is real", b.Scope, siteVerbSplit)
	}
	if b.Impl != nil {
		t.Fatal("create carries a shared Impl — the two nouns build different request bodies")
	}
	fleet := reflect.ValueOf(b.handler(siteSpellingFleet)).Pointer()
	spawner := reflect.ValueOf(b.handler(siteSpellingSpawner)).Pointer()
	if fleet == spawner {
		t.Fatal("`bp sites create` and `bp cloud site create` reach the same handler — " +
			"one of the two kinds is now unreachable")
	}

	// And prove it at the wire: the two bodies differ in the keys that name the
	// kind. `bp sites create` sends the container's barkpark slug; the spawner
	// sends the dataset triple and the instance it spawns on.
	var got []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Both spellings resolve a Barkpark first (the container by slug, the
		// spawner by instance name), so the fake answers that read before the
		// create body it is here to capture.
		if r.Method == "GET" && r.URL.Path == "/v1/barkparks" {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"barkparks":[{"id":"bp-uuid-2","name":"box-1","slug":"blog","mode":"managed","status":"live"}]}`))
			return
		}
		if r.Method == "POST" && r.URL.Path == "/v1/sites" {
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			got = append(got, body)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"site":{"id":"` + matrixSiteID + `","name":"blog","slug":"blog"}}`))
	}))
	defer srv.Close()
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)

	runAtSpelling(t, siteSpellingFleet, "table", globals{}, []string{"create", "--barkpark", "blog", "--name", "Blog"})
	runAtSpelling(t, siteSpellingSpawner, "table", globals{}, []string{"create", "--name", "Blog", "--dataset", "acme/blog/production", "--instance", "box-1"})
	if len(got) != 2 {
		t.Fatalf("expected both spellings to POST /v1/sites, got %d bodies: %v", len(got), got)
	}
	if reflect.DeepEqual(got[0], got[1]) {
		t.Fatalf("both create spellings sent the SAME body %v — the kind difference was aliased away", got[0])
	}
	if _, ok := got[1]["dataset"]; !ok {
		t.Errorf("`bp cloud site create` body has no dataset key: %v", got[1])
	}
	if _, ok := got[0]["dataset"]; ok {
		t.Errorf("`bp sites create` (container) sent a dataset key: %v", got[0])
	}
}

// `bp sites deploy` must REFUSE and name both doors. The row asked for help
// with no ambiguous deploy instruction; a third spelling that silently picked
// one of the two deploy models would be exactly that ambiguity.
func TestSitesDeployRefusesAndNamesBothDoors(t *testing.T) {
	withTempConfigHome(t)
	stdout, stderr, code := runAtSpelling(t, siteSpellingFleet, "table", globals{}, []string{"deploy", "blog"})
	if code != exitUsage {
		t.Fatalf("`bp sites deploy` exit = %d, want %d (usage)\n%s%s", code, exitUsage, stdout, stderr)
	}
	msg := stdout + stderr
	for _, want := range []string{"bp deploy <site>", "bp cloud site deploy <site>"} {
		if !strings.Contains(msg, want) {
			t.Errorf("`bp sites deploy` refusal never names %q:\n%s", want, msg)
		}
	}
}

// --- the matrix itself renders what the table holds --------------------------

// The matrix is DERIVED, not retyped: every verb in the table appears in the
// render, and the reserved instance-level verbs are named as reserved.
func TestSiteMatrixRenderCoversTheTable(t *testing.T) {
	stdout, _, code := runAtSpelling(t, siteSpellingSpawner, "table", globals{}, []string{"matrix"})
	if code != exitOK {
		t.Fatalf("`bp cloud site matrix` exit = %d, want 0\n%s", code, stdout)
	}
	for _, b := range siteVerbMatrix {
		if !strings.Contains(stdout, b.Verb) {
			t.Errorf("matrix render omits verb %q:\n%s", b.Verb, stdout)
		}
	}
	for _, want := range []string{"bp cloud deploy", "bp cloud rollback", "RESERVED"} {
		if !strings.Contains(stdout, want) {
			t.Errorf("matrix render omits %q — the reserved instance-level meaning is unstated:\n%s", want, stdout)
		}
	}

	jsonOut, _, code := runAtSpelling(t, siteSpellingFleet, "json", globals{}, []string{"matrix"})
	if code != exitOK {
		t.Fatalf("`bp sites matrix -o json` exit = %d, want 0\n%s", code, jsonOut)
	}
	var env struct {
		Verbs []struct {
			Verb      string   `json:"verb"`
			Scope     string   `json:"scope"`
			Spellings []string `json:"spellings"`
		} `json:"verbs"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		t.Fatalf("matrix -o json is not JSON: %v\n%s", err, jsonOut)
	}
	if len(env.Verbs) != len(siteVerbMatrix)+len(siteReservedVerbs) {
		t.Fatalf("matrix -o json carries %d rows, table has %d", len(env.Verbs), len(siteVerbMatrix)+len(siteReservedVerbs))
	}
	for _, row := range env.Verbs {
		if row.Scope == string(siteVerbShared) && len(row.Spellings) != 2 {
			t.Errorf("shared verb %q reports spellings %v, want both nouns", row.Verb, row.Spellings)
		}
		if row.Scope == string(siteVerbReserved) && len(row.Spellings) != 0 {
			t.Errorf("reserved verb %q reports spellings %v, want none", row.Verb, row.Spellings)
		}
	}
}

// An unknown verb refuses identically at both nouns, naming the door that does
// answer — the message a stranger at the wrong noun actually reads.
func TestSiteUnknownVerbRefusesAtBothSpellings(t *testing.T) {
	withTempConfigHome(t)
	for _, spelling := range []string{siteSpellingFleet, siteSpellingSpawner} {
		stdout, stderr, code := runAtSpelling(t, spelling, "table", globals{}, []string{"frobnicate"})
		if code != exitUsage {
			t.Errorf("%s frobnicate exit = %d, want %d", spelling, code, exitUsage)
		}
		if !strings.Contains(stdout+stderr, "frobnicate") {
			t.Errorf("%s: refusal does not name the verb:\n%s%s", spelling, stdout, stderr)
		}
	}
}

// Both dispatchers must route through the matrix and keep no switch of their
// own — a `case` arm reintroduced in either one is a verb only that noun
// answers, which is the whole defect.
func TestSiteDispatchersKeepNoSwitchOfTheirOwn(t *testing.T) {
	bodies := packageFuncBodies(t)
	for _, fn := range []string{"runSites", "runCloudSite"} {
		body, ok := bodies[fn]
		if !ok {
			t.Fatalf("%s not found — the scanner or the dispatcher moved; fix this guard", fn)
		}
		if !strings.Contains(body, "dispatchSiteVerb") {
			t.Errorf("%s does not route through dispatchSiteVerb", fn)
		}
		if strings.Contains(body, "switch verb") || strings.Contains(body, "case \"ls\"") {
			t.Errorf("%s grew a verb switch again — declare the verb in siteVerbMatrix instead:\n%s", fn, body)
		}
	}
}
