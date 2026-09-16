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
	t   *testing.T
	log []string
}

func (m *matrixCloud) reset() { m.log = nil }

func (m *matrixCloud) serve() *httptest.Server {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rec := r.Method + " " + r.URL.Path
		if r.URL.RawQuery != "" {
			rec += "?" + r.URL.RawQuery
		}
		m.log = append(m.log, rec)
		body, status := matrixFixture(r.Method, r.URL.Path)
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	m.t.Cleanup(srv.Close)
	withTempConfigHome(m.t)
	seedCloudLogin(m.t, srv.URL)
	return srv
}

func matrixFixture(method, path string) (string, int) {
	site := `{"id":"` + matrixSiteID + `","name":"blog","slug":"blog","kind":"static",` +
		`"framework":"astro","domains":["blog.example.com"],"prebuilt_enabled":true,` +
		`"workspace":"acme","project":"blog","dataset":"production"}`
	switch {
	case method == "GET" && path == "/v1/sites":
		return `{"sites":[` + site + `]}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID+"/deployments":
		return `{"deployments":[],"next_cursor":null}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID+"/doctor":
		return `{"report":{"site_id":"` + matrixSiteID + `","substrates":[]}}`, http.StatusOK
	case method == "GET" && path == "/v1/sites/"+matrixSiteID:
		return `{"site":` + site + `}`, http.StatusOK
	}
	return `{"error":"not_found"}`, http.StatusNotFound
}

// runAtSpelling drives one verb through one spelling with a fresh writer.
func runAtSpelling(t *testing.T, spelling, output string, argv []string) (string, string, int) {
	t.Helper()
	orig := siteDeployPoll
	siteDeployPoll = 0
	t.Cleanup(func() { siteDeployPoll = orig })
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	var code int
	if spelling == siteSpellingFleet {
		code = runSites(w, argv)
	} else {
		code = runCloudSite(w, globals{}, argv)
	}
	return sout.String(), serr.String(), code
}

// THE QUIET ARM. Every shared verb, both spellings, one recording server: the
// request sequence, stdout and exit code must be identical. It says nothing
// while the aliasing is a pure rename of the door, and names the verb the
// moment one spelling starts calling a different URL or printing a different
// shape.
func TestSiteSharedVerbsSameURLAndOutputAtBothSpellings(t *testing.T) {
	cases := [][]string{
		{"ls"},
		{"list"},
		{"show", matrixSiteID},
		{"get", matrixSiteID},
		{"deployments", matrixSiteID},
		{"deploys", matrixSiteID},
		{"status", matrixSiteID},
		{"doctor", matrixSiteID},
		{"logs", matrixSiteID},
		{"matrix"},
	}
	for _, output := range []string{"table", "json"} {
		for _, argv := range cases {
			name := strings.Join(argv, " ") + "/" + output
			t.Run(name, func(t *testing.T) {
				m := &matrixCloud{t: t}
				m.serve()

				m.reset()
				fleetOut, fleetErr, fleetCode := runAtSpelling(t, siteSpellingFleet, output, argv)
				fleetReqs := append([]string(nil), m.log...)

				m.reset()
				spawnOut, spawnErr, spawnCode := runAtSpelling(t, siteSpellingSpawner, output, argv)
				spawnReqs := append([]string(nil), m.log...)

				if !reflect.DeepEqual(fleetReqs, spawnReqs) {
					t.Errorf("`bp sites %s` and `bp cloud site %s` call DIFFERENT URLs:\n  sites:      %v\n  cloud site: %v",
						name, name, fleetReqs, spawnReqs)
				}
				if fleetOut != spawnOut {
					t.Errorf("`bp sites %s` and `bp cloud site %s` print different stdout:\n--- sites ---\n%s\n--- cloud site ---\n%s",
						name, name, fleetOut, spawnOut)
				}
				if fleetErr != spawnErr {
					t.Errorf("%s: stderr differs:\n--- sites ---\n%s\n--- cloud site ---\n%s", name, fleetErr, spawnErr)
				}
				if fleetCode != spawnCode {
					t.Errorf("%s: exit differs — sites=%d cloud site=%d", name, fleetCode, spawnCode)
				}
				// Non-vacuity: a run that made no request AND printed nothing
				// compares two nothings. `matrix` is offline by design; every
				// other case must have touched the plane.
				if argv[0] != "matrix" && len(fleetReqs) == 0 {
					t.Fatalf("%s made no request at either spelling — the comparison is vacuous", name)
				}
			})
		}
	}
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

	runAtSpelling(t, siteSpellingFleet, "table", []string{"create", "--barkpark", "blog", "--name", "Blog"})
	runAtSpelling(t, siteSpellingSpawner, "table", []string{"create", "--name", "Blog", "--dataset", "acme/blog/production", "--instance", "box-1"})
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
	stdout, stderr, code := runAtSpelling(t, siteSpellingFleet, "table", []string{"deploy", "blog"})
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
	stdout, _, code := runAtSpelling(t, siteSpellingSpawner, "table", []string{"matrix"})
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

	jsonOut, _, code := runAtSpelling(t, siteSpellingFleet, "json", []string{"matrix"})
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
		stdout, stderr, code := runAtSpelling(t, spelling, "table", []string{"frobnicate"})
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
