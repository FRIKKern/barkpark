package cli

// cloud_deploy_census_cmd_test.go proves `bp cloud deployments` against a fake
// control plane. The load-bearing assertions are the REFUSALS: this verb exists
// because a deploy ledger that nobody can read a number out of and a deploy
// ledger that reads zero are indistinguishable to an operator, so every way of
// failing to read one must render as a refusal that names itself.
//
// Covered: the verb is reachable through the `bp cloud` dispatcher and listed in
// `bp cloud -h`; the headline line carries rate + volume + denominator together
// against TODAY's payload and against the dr-w8-s1 payload (both D34
// conventions); all four refusal states (401, 403, 422, and the in-band
// below-min_sample refusal) render as refusals and never as a number; a 403 body
// fed through the whole command can NOT produce a failure count (the
// comforting-zero regression); `-o json` re-emits the envelope verbatim while
// the human render is the default; and the window is client-computed, sent on
// the wire, and printed.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// censusTodayEnvelope is the payload the DEPLOYED control plane sends: one rate
// node denominated on attempted rows, no `live`, no `terminal_failure_rate`, no
// `basis`. The reader must be complete against this and must not wait for s1.
const censusTodayEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "failure_rate": {"sample": 2216, "pct": 37.55, "numerator": 832, "min_sample": 200, "refused": false, "reason": null},
  "classes": [
    {"class": "BOX_BUSY_409", "label": "the instance refused the deploy (409)", "count": 500,
     "share": {"sample": 832, "pct": 60.1, "numerator": 500, "min_sample": 200, "refused": false, "reason": null}},
    {"class": "DOC_ID_EMPTY", "label": "the cause went unrecorded", "count": 332,
     "share": {"sample": 832, "pct": 39.9, "numerator": 332, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "deferred": [
    {"class": "BOX_BUSY_DEFERRED", "label": "the box was busy; re-queued", "count": 793,
     "share": {"sample": 2216, "pct": 35.78, "numerator": 793, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-alpha", "volume": 1200, "failed": 500, "deferred": 400,
     "failure_rate": {"sample": 1200, "pct": 41.67, "numerator": 500, "min_sample": 200, "refused": false, "reason": null},
     "top_class": "BOX_BUSY_409"},
    {"site_id": "site-beta", "volume": 1016, "failed": 332, "deferred": 393,
     "failure_rate": {"sample": 1016, "pct": 32.68, "numerator": 332, "min_sample": 200, "refused": false, "reason": null},
     "top_class": null}
  ],
  "min_sample": 200
}`

// censusS1Envelope is the SAME window after dr-w8-s1 lands: `live`, a `basis` on
// the rate node, and the second D34 convention (failures over terminal rows).
const censusS1Envelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "live": 591,
  "failure_rate": {"sample": 2216, "pct": 37.55, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "attempted rows (deferrals included)"},
  "terminal_failure_rate": {"sample": 1423, "pct": 58.47, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "terminal rows (failed + live)"},
  "classes": [],
  "deferred": [
    {"class": "BOX_BUSY_DEFERRED", "label": "the box was busy; re-queued", "count": 793,
     "share": {"sample": 2216, "pct": 35.78, "numerator": 793, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200
}`

// censusTeamScopedEnvelope is what the TEAM route sends (dr-w16-s6): the same
// census body PLUS a `scope` node naming the population. registered_sites (13)
// deliberately exceeds the two rows in `sites` — a registered site that has
// never deployed is counted there and absent here.
const censusTeamScopedEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "failure_rate": {"sample": 2216, "pct": 37.55, "numerator": 832, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-alpha", "volume": 1200, "failed": 500, "deferred": 400,
     "failure_rate": {"sample": 1200, "pct": 41.67, "numerator": 500, "min_sample": 200, "refused": false, "reason": null},
     "top_class": "BOX_BUSY_409"}
  ],
  "min_sample": 200,
  "scope": {
    "team": "guerrilla",
    "site_ids": ["site-alpha", "site-beta"],
    "registered_sites": 13,
    "registered_sites_population": "sites registered to this team and inside this request's scope"
  }
}`

// censusThinEnvelope is a 200 whose RATE is refused: a real window, real counts,
// and no percentage — the in-band refusal (the fourth state).
const censusThinEnvelope = `{
  "window": {"from": "2026-08-06T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 12,
  "failed": 3,
  "failure_rate": {"sample": 12, "pct": null, "numerator": 3, "min_sample": 200, "refused": true, "reason": "sample 12 below min_sample 200"},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200
}`

// newCensusServer stands up a fake control plane answering the census route with
// the given status + body, seeds a cloud login pointed at it, and records the
// method, path, raw query and Authorization header it saw — so a test can prove
// the window really travelled and the Bearer really went with it.
func newCensusServer(t *testing.T, status int, body string) (method, path, query, auth *string) {
	t.Helper()
	var m, p, q, a string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, p, q, a = r.Method, r.URL.Path, r.URL.RawQuery, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &p, &q, &a
}

// runDeployments drives runCloudDeployments with an in-memory writer at the
// chosen output shape, returning stdout, stderr, exit.
func runDeployments(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudDeployments(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// pinCensusClock freezes the default-window clock so the window a test asserts
// is the window the code computed, byte for byte.
func pinCensusClock(t *testing.T, at time.Time) {
	t.Helper()
	prev := deployCensusNow
	deployCensusNow = func() time.Time { return at }
	t.Cleanup(func() { deployCensusNow = prev })
}

// TestCloudDeploymentsIsReachable: the verb dispatches through `bp cloud` (not
// just through its own function) and `bp cloud -h` lists it — a command nobody
// can find is the same as a command that does not exist.
func TestCloudDeploymentsIsReachable(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	if code := runCloud(w, globals{}, []string{"deployments", "--help"}); code != exitOK {
		t.Fatalf("bp cloud deployments --help exit = %d, want 0 (stderr: %s)", code, serr.String())
	}
	if !strings.Contains(sout.String(), "bp cloud deployments") {
		t.Fatalf("help did not come from the deployments verb:\n%s", sout.String())
	}

	var hout, herr bytes.Buffer
	hw := newWriter(&hout, &herr)
	printCloudHelp(hw)
	if !strings.Contains(hout.String(), "deployments") {
		t.Fatalf("`bp cloud -h` does not list the deployments verb:\n%s", hout.String())
	}
}

// TestCloudDeploymentsTodayPayload: against the payload the control plane sends
// TODAY, the headline carries the rate, the volume and the DENOMINATOR on one
// line, and says which denominator it is — including that this control plane
// sends no terminal-row rate at all.
func TestCloudDeploymentsTodayPayload(t *testing.T) {
	method, path, query, auth := newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	// THE STRUCTURAL PIN (D281 shape), WIDENED — never loosened. It was an exact
	// equality against /v1/operator/deploy-ledger/census, the route that is
	// empty by construction in production; dr-w18-s1 re-points the reader at the
	// TEAM route and this pin moves WITH it, still as an exact equality. It is
	// deliberately not a substring, an OR, or a regex: this assertion is the only
	// thing in the tree that can catch a future silent re-point, and any of those
	// three would let the operator path back in unnoticed.
	if *method != "GET" || *path != "/v1/deploy-ledger/census" {
		t.Fatalf("hit %s %s, want GET /v1/deploy-ledger/census", *method, *path)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	// The window travelled — both bounds, pinned by the client.
	if !strings.Contains(*query, "from=2026-07-31T00%3A00%3A00Z") || !strings.Contains(*query, "to=2026-08-07T00%3A00%3A00Z") {
		t.Fatalf("query = %q, want a client-pinned from AND to", *query)
	}

	headline := censusLineContaining(t, stdout, "of 2216 attempted")
	for _, want := range []string{"37.5%", "832 failed", "793 deferred", "ATTEMPTED"} {
		if !strings.Contains(headline, want) {
			t.Fatalf("headline %q missing %q — rate, volume and denominator must ride the SAME line", headline, want)
		}
	}
	if !strings.Contains(stdout, "2026-07-31T00:00:00Z → 2026-08-07T00:00:00Z") {
		t.Fatalf("the window must be printed, not merely sent:\n%s", stdout)
	}
	if !strings.Contains(stdout, "BOX_BUSY_409") || !strings.Contains(stdout, "site-alpha") {
		t.Fatalf("classes and sites should render:\n%s", stdout)
	}
	// A site with no failures gets an em-dash, never an invented top class.
	if !strings.Contains(stdout, "site-beta") {
		t.Fatalf("second site missing:\n%s", stdout)
	}
}

// TestCloudDeploymentsBothConventions: when the payload carries dr-w8-s1's
// `live` + `terminal_failure_rate`, BOTH D34 conventions print — each with its
// own denominator.
func TestCloudDeploymentsBothConventions(t *testing.T) {
	newCensusServer(t, 200, censusS1Envelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	headline := censusLineContaining(t, stdout, "of 2216 attempted")
	for _, want := range []string{"37.5%", "832 failed", "793 deferred", "591 live", "58.5% of 1423 terminal"} {
		if !strings.Contains(headline, want) {
			t.Fatalf("headline %q missing %q — both conventions belong on the one line", headline, want)
		}
	}
	if !strings.Contains(stdout, "basis: attempted rows (deferrals included)") {
		t.Fatalf("the rate node's basis must be printed when the control plane sends it:\n%s", stdout)
	}
}

// TestCloudDeploymentsInBandRefusal: a 200 whose rate node REFUSES prints the
// refusal and no percentage at all — the counts are real, the rate is not.
func TestCloudDeploymentsInBandRefusal(t *testing.T) {
	newCensusServer(t, 200, censusThinEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--days", "1")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the request succeeded; the RATE was refused)\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "NO RATE") || !strings.Contains(stdout, "sample 12 below min_sample 200") {
		t.Fatalf("the in-band refusal must be rendered verbatim:\n%s", stdout)
	}
	if pctRe.MatchString(stdout) {
		t.Fatalf("a refused rate must print NO percentage anywhere:\n%s", stdout)
	}
}

// TestCloudDeploymentsScopeIsNamed: the TABLE render names the population the
// numbers were taken over, and says so when the control plane did not.
//
// IT ASSERTS THE TABLE ARM ON PURPOSE. emitDeployCensusRaw prints census.Raw
// verbatim, so `-o json` already carries the whole scope node whether or not any
// Go field models it — a json assertion here would pass on a URL-only edit and
// prove nothing. And the writer defaults to json when piped, so `-o table` is
// passed explicitly rather than assumed.
func TestCloudDeploymentsScopeIsNamed(t *testing.T) {
	t.Run("scope node present names the team and labels the count", func(t *testing.T) {
		newCensusServer(t, 200, censusTeamScopedEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

		stdout, stderr, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		scope := censusLineContaining(t, stdout, "scope:")
		for _, want := range []string{"team guerrilla", "13 sites registered", "not the number that deployed in the window"} {
			if !strings.Contains(scope, want) {
				t.Fatalf("scope line %q missing %q — the count must travel with what it counts", scope, want)
			}
		}
	})

	t.Run("no scope node renders NOT NAMED, never an empty team", func(t *testing.T) {
		// censusTodayEnvelope carries no `scope` key at all — the operator route
		// and any control plane predating dr-w16-s6. The pointer field decodes
		// that to nil, and nil must SAY the population is unnamed.
		newCensusServer(t, 200, censusTodayEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

		stdout, stderr, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		scope := censusLineContaining(t, stdout, "scope:")
		if !strings.Contains(scope, "population NOT NAMED") {
			t.Fatalf("scope line %q must say the population is NOT NAMED", scope)
		}
		if strings.Contains(scope, "team ") {
			t.Fatalf("an absent scope node must never render a team at all, got %q", scope)
		}
	})
}

// TestCloudDeploymentsScopeDecodesAsPointer proves the FIELD, not the render:
// an absent `scope` key decodes to nil rather than to a zero-valued struct whose
// team is "".
func TestCloudDeploymentsScopeDecodesAsPointer(t *testing.T) {
	var with, without cloudclient.DeployCensus
	if err := json.Unmarshal([]byte(censusTeamScopedEnvelope), &with); err != nil {
		t.Fatalf("decode scoped envelope: %v", err)
	}
	if err := json.Unmarshal([]byte(censusTodayEnvelope), &without); err != nil {
		t.Fatalf("decode unscoped envelope: %v", err)
	}
	if with.Scope == nil || with.Scope.Team != "guerrilla" || with.Scope.RegisteredSites != 13 {
		t.Fatalf("scope node did not decode: %#v", with.Scope)
	}
	if without.Scope != nil {
		t.Fatalf("an absent scope key must decode to nil, got %#v", without.Scope)
	}
}

// TestCloudDeploymentsRefusals walks the HTTP refusal states. Each must
// exit on the ladder, name what refused, and print NO count — a refusal that
// renders as "0 failed" is the exact defect this verb exists to prevent.
func TestCloudDeploymentsRefusals(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantExit int
		wantIn   []string
		// wantOut is the FORBIDDEN vocabulary: a remedy that cannot work for
		// this refusal. A refusal sentence is only honest if it also stops
		// saying the wrong thing.
		wantOut []string
	}{
		{
			name:     "401 unauthorized",
			status:   401,
			body:     `{"error":"unauthorized"}`,
			wantExit: exitAuth,
			wantIn:   []string{"401 unauthorized", "NOT a population with zero failures", "bp login"},
		},
		{
			name:     "403 forbidden",
			status:   403,
			body:     `{"error":"forbidden","scope":"platform","required":"platform_operator"}`,
			wantExit: exitAuth,
			wantIn: []string{
				"403 forbidden",
				"scope=platform",
				"required=platform_operator",
				`ability "read"`,
			},
			wantOut: []string{
				// On the TEAM route the operator allowlist has nothing to do
				// with the refusal, so sending a team owner to edit it is a
				// remedy that cannot work.
				"PLATFORM_ADMIN_EMAILS",
			},
		},
		{
			// The two 422s are DIFFERENT refusals and must not share a sentence:
			// a teamless caller told to widen the window is sent round a loop
			// that cannot terminate.
			name:     "422 no_team",
			status:   422,
			body:     `{"error":"no_team"}`,
			wantExit: exitValidation,
			wantIn:   []string{"422 no_team", "belongs to no team", "no window can fix it"},
			wantOut:  []string{"--from/--to", "widen it with --days"},
		},
		{
			name:     "422 invalid_window",
			status:   422,
			body:     `{"error":"invalid_window","detail":"from must be earlier than to"}`,
			wantExit: exitValidation,
			wantIn:   []string{"422 invalid_window", "from must be earlier than to", "Nothing was read"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			newCensusServer(t, tc.status, tc.body)
			pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

			stdout, stderr, code := runDeployments(t, "table")
			if code != tc.wantExit {
				t.Fatalf("exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", code, tc.wantExit, stdout, stderr)
			}
			all := stdout + stderr
			for _, want := range tc.wantIn {
				if !strings.Contains(all, want) {
					t.Fatalf("refusal missing %q:\n%s", want, all)
				}
			}
			for _, unwanted := range tc.wantOut {
				if strings.Contains(all, unwanted) {
					t.Fatalf("refusal offers a remedy that cannot work (%q):\n%s", unwanted, all)
				}
			}
			if pctRe.MatchString(all) {
				t.Fatalf("a refusal must never render a percentage:\n%s", all)
			}
			// A REFUSAL HAS NO SCOPE LINE BENEATH IT TO CORRECT AN OVER-CLAIM.
			// On a 200 the render names the population under the window; here
			// there is nothing to name, because the control plane never said
			// which team it would have covered. A refusal that calls this read
			// "the fleet deploy census" tells a team owner the FLEET is
			// unreadable when only their own census was refused — the same
			// class of over-statement this epic exists to delete. This reader
			// is team-scoped (GET /v1/deploy-ledger/census) on every path.
			if strings.Contains(all, "fleet deploy census") {
				t.Fatalf("a refusal must not claim fleet scope on a team-scoped read:\n%s", all)
			}
			// The window is named even when nothing could be read, so the operator
			// knows which population they FAILED to measure.
			if !strings.Contains(all, "2026-08-07T00:00:00Z") {
				t.Fatalf("refusal must still name the window it asked for:\n%s", all)
			}
		})
	}
}

// pctRe matches any rendered percentage. Used to prove a refusal path emits none.
var pctRe = regexp.MustCompile(`\d+(\.\d+)?%`)

// censusCountRe matches the render's count phrases ("832 failed", "0 failed",
// "2216 attempted"). A refusal that emits one of these is claiming to have
// counted something it never read.
var censusCountRe = regexp.MustCompile(`\d+ (failed|attempted|deferred|live|terminal)`)

// TestCloudDeploymentsForbiddenNeverPrintsACount is the comforting-zero
// regression, pinned at the WHOLE-COMMAND level: the 403 body goes in one end
// and the render must not contain a failure count at the other. A reader that
// coalesces the refusal into a zero-valued census would print "0 failed of 0
// attempted" here — a fleet that looks perfect because nobody could look at it.
func TestCloudDeploymentsForbiddenNeverPrintsACount(t *testing.T) {
	newCensusServer(t, 403, `{"error":"forbidden","scope":"platform","required":"platform_operator"}`)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	// The COUNT assertion runs FIRST, before the exit-code one, so this test
	// fails for its own reason: mutating the reader to skip its error branch
	// (`if false && derr != nil`) makes it report `a 403 rendered a count
	// ("0 attempted")`, not merely a wrong exit code.
	all := stdout + stderr
	if m := censusCountRe.FindString(all); m != "" {
		t.Fatalf("a 403 rendered a count (%q) — that is the comforting zero:\n%s", m, all)
	}
	if strings.Contains(all, "0 failed") {
		t.Fatalf("a 403 must never render a failure count:\n%s", all)
	}
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d", code, exitAuth)
	}
}

// TestCloudDeploymentsJSONIsVerbatim: `-o json` re-emits the control plane's
// census envelope BYTES (the CLI never becomes a second definition of the
// contract), and the human render — not JSON — is the default.
func TestCloudDeploymentsJSONIsVerbatim(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "json")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	var got, want any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("-o json did not emit JSON: %v\n%s", err, stdout)
	}
	if err := json.Unmarshal([]byte(censusTodayEnvelope), &want); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}
	if strings.TrimSpace(stdout) != strings.TrimSpace(censusTodayEnvelope) {
		t.Fatalf("-o json must be the envelope bytes verbatim:\ngot:\n%s\nwant:\n%s", stdout, censusTodayEnvelope)
	}
}

// TestCloudDeploymentsWindowFlags: an explicitly pinned window travels as given,
// and the half-pinned / double-pinned forms are refused rather than silently
// completed into something the caller did not choose.
func TestCloudDeploymentsWindowFlags(t *testing.T) {
	_, _, query, _ := newCensusServer(t, 200, censusTodayEnvelope)

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-07-31", "--to", "2026-08-07T00:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(*query, "from=2026-07-31T00%3A00%3A00Z") {
		t.Fatalf("a bare --from date must widen to midnight UTC; query = %q", *query)
	}
	if !strings.Contains(stdout, "2026-07-31T00:00:00Z → 2026-08-07T00:00:00Z (7 days)") {
		t.Fatalf("the pinned window must be printed with its width:\n%s", stdout)
	}

	if _, _, code := runDeployments(t, "table", "--from", "2026-07-31"); code != exitUsage {
		t.Fatalf("half-pinned window exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runDeployments(t, "table", "--days", "3", "--to", "2026-08-07"); code != exitUsage {
		t.Fatalf("--days with --to exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runDeployments(t, "table", "--days", "0"); code != exitUsage {
		t.Fatalf("--days 0 exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runDeployments(t, "table", "--from", "yesterday", "--to", "today"); code != exitUsage {
		t.Fatalf("unparseable window exit = %d, want %d", code, exitUsage)
	}
}

// TestCloudDeploymentsNotLoggedIn: with no cloud token the verb says so and
// never reaches the network — and, again, prints no number.
func TestCloudDeploymentsNotLoggedIn(t *testing.T) {
	withTempConfigHome(t)
	stdout, stderr, code := runDeployments(t, "table")
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d", code, exitAuth)
	}
	if !strings.Contains(stdout+stderr, "bp login") {
		t.Fatalf("missing the login pointer:\n%s%s", stdout, stderr)
	}
}

// censusLineContaining returns the single rendered line carrying needle, failing
// the test when there is none — so "the rate and its denominator are on the SAME
// line" is asserted as one line, not as two lucky substrings of the whole page.
func censusLineContaining(t *testing.T, out, needle string) string {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	t.Fatalf("no line contains %q:\n%s", needle, out)
	return ""
}

// censusLiveEnvelope is the dr-w16-s2 payload: the s1 census PLUS `live_rate`
// (live-per-attempt), `in_flight`, `cancelled` and `residual` — every state an
// attempt can end in, named.
//
// `cancelled` IS SYNTHETIC HERE AND CANNOT BE ANYTHING ELSE. It has never
// existed on prod: 0 of 31,137 deployment rows all-time, both spellings, since
// 2026-07-14; the lifetime status vocabulary is exactly failed / live /
// deferred. Two producers exist and neither has ever fired. A test that waited
// for a prod render of it would wait forever, and an acceptance that claimed one
// would be vacuous — so it is proved here, on an envelope made by hand.
const censusLiveEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "live": 591,
  "in_flight": 9,
  "cancelled": 4,
  "residual": 0,
  "failure_rate": {"sample": 2216, "pct": 37.55, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "attempted rows (deferrals included)"},
  "live_rate": {"sample": 2216, "pct": 26.67, "numerator": 591, "min_sample": 200, "refused": false, "reason": null, "basis": "attempted rows (deferrals included)"},
  "terminal_failure_rate": {"sample": 1423, "pct": 58.47, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "terminal rows (failed + live)"},
  "classes": [],
  "deferred": [
    {"class": "BOX_BUSY_DEFERRED", "label": "the box was busy; re-queued", "count": 793,
     "share": {"sample": 2216, "pct": 35.78, "numerator": 793, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200
}`

// TestCloudDeploymentsLivePerAttemptLeadsTheHeadline: when the control plane
// sends `live_rate`, the headline LEADS with it and the failure rate becomes a
// labelled sibling — additively, on the same line, beside the same cohort
// parenthetical. A census whose headline answers only "how bad is it" never
// answers "did anything ship", which on this fleet is the question.
func TestCloudDeploymentsLivePerAttemptLeadsTheHeadline(t *testing.T) {
	newCensusServer(t, 200, censusLiveEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	headline := censusLineContaining(t, stdout, "of 2216 attempted")
	for _, want := range []string{
		"live 26.7% of 2216 attempted", "failure 37.5% of 2216 attempted",
		"832 failed", "793 deferred", "591 live", "58.5% of 1423 terminal",
		"9 in flight", "4 cancelled", "0 residual",
	} {
		if !strings.Contains(headline, want) {
			t.Fatalf("headline %q missing %q — live-per-attempt is co-equal and rides the SAME line", headline, want)
		}
	}
	if strings.Index(headline, "live 26.7%") > strings.Index(headline, "failure 37.5%") {
		t.Fatalf("the live rate must LEAD, not trail the failure rate: %q", headline)
	}
	// ONE line carries the denominator phrase. A live rate on a line of its own
	// would be a second "of N attempted" line, and every reader that reaches for
	// the headline by that phrase — this test included — takes the first one.
	n := 0
	for _, line := range strings.Split(stdout, "\n") {
		if strings.Contains(line, "of 2216 attempted") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("%d lines carry \"of 2216 attempted\", want exactly 1:\n%s", n, stdout)
	}
}

// TestDeployCensusHeadlineRendersLiveInBOTHBranches is the anti-vacuity pin.
//
// deployCensusHeadline has two branches: the ok-rate branch and the REFUSED
// branch. A prepend applied only to the ok branch drops the live rate exactly
// when the failure rate refused — and it passes the package's existing guards
// vacuously, because the only refusing fixture carries no live node, so the term
// is never rendered and nothing can fire. This test renders the refused branch
// WITH a live node and asserts the term is there, so an ok-branch-only
// implementation reds here for its own reason.
func TestDeployCensusHeadlineRendersLiveInBOTHBranches(t *testing.T) {
	refusedFailure := cloudclient.DeployRate{Sample: 12, Numerator: 3, MinSample: 200, Refused: true, Reason: "sample 12 below min_sample 200"}

	// (a) An HONEST live node beside a refused failure rate: the percentage is
	// the live one, and it must survive into the refused branch.
	pct := 25.0
	honest := cloudclient.DeployCensus{
		Failed: 3, MinSample: 200, FailureRate: refusedFailure,
		LivePerAttempt: &cloudclient.DeployRate{Sample: 12, Pct: &pct, Numerator: 3, MinSample: 200},
	}
	head := deployCensusHeadline(honest)
	if !strings.HasPrefix(head, "live 25.0% of 12 attempted") {
		t.Fatalf("the refused branch dropped the live term — the prepend is on the ok branch only: %q", head)
	}
	if !strings.Contains(head, "failure NO RATE") {
		t.Fatalf("the refused failure rate must still refuse, in its own labelled place: %q", head)
	}

	// (b) A live node that itself REFUSES prints the refusal and NO percentage —
	// the same discipline the failure rate has always had.
	refused := cloudclient.DeployCensus{
		Failed: 3, MinSample: 200, FailureRate: refusedFailure,
		LivePerAttempt: &cloudclient.DeployRate{Sample: 12, Numerator: 3, MinSample: 200, Refused: true, Reason: "sample 12 below min_sample 200"},
	}
	head = deployCensusHeadline(refused)
	if !strings.HasPrefix(head, "live per attempt: NO RATE — the control plane refused a percentage: sample 12 below min_sample 200") {
		t.Fatalf("a refused live node must refuse in words, in the leading position: %q", head)
	}
	if pctRe.MatchString(head) {
		t.Fatalf("a refused live rate must print NO percentage: %q", head)
	}

	// (c) NO live node at all (every control plane older than dr-w16-s2): the
	// headline says so. Silence would read as a fleet that ships nothing.
	head = deployCensusHeadline(cloudclient.DeployCensus{Failed: 3, MinSample: 200, FailureRate: refusedFailure})
	if !strings.HasPrefix(head, "live per attempt: NOT SENT") {
		t.Fatalf("an absent live rate must be NAMED absent, never omitted: %q", head)
	}
}

// TestCloudDeploymentsBasisNamesRowsNotAttempts: the basis line says what its
// denominator actually counts. The control plane calls it "attempted rows",
// which reads as ATTEMPTS; it is rows, and 1,584 attempts on 2026-08-06 minted
// no row at all, so every rate above it is a ceiling. The line prints on EVERY
// payload, including the one that sends no basis of its own.
func TestCloudDeploymentsBasisNamesRowsNotAttempts(t *testing.T) {
	for _, tc := range []struct {
		name     string
		envelope string
		wantIn   []string
	}{
		{
			name:     "control plane sent a basis",
			envelope: censusS1Envelope,
			// The control plane's own words are kept, verbatim, and corrected after.
			wantIn: []string{"attempted rows (deferrals included)", "deployment ROWS, not attempts", "1,584 attempts excluded", "CEILING"},
		},
		{
			name:     "control plane sent no basis",
			envelope: censusTodayEnvelope,
			wantIn:   []string{"deployment ROWS, not attempts", "coalesces onto an in-flight build", "CEILING"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newCensusServer(t, 200, tc.envelope)
			pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

			stdout, stderr, code := runDeployments(t, "table")
			if code != exitOK {
				t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
			}
			basis := censusLineContaining(t, stdout, "basis:")
			for _, want := range tc.wantIn {
				if !strings.Contains(basis, want) {
					t.Fatalf("basis line %q missing %q", basis, want)
				}
			}
			// The basis line rides beside rates that may have REFUSED, so it may
			// never carry a percentage of its own.
			if pctRe.MatchString(basis) {
				t.Fatalf("the basis line must carry no percentage: %q", basis)
			}
		})
	}
}

// censusDeliveryEnvelope is the census WITH dr-w11-s4's `delivery` node. Its key
// set is the one `DeployLedger.delivery/3` emits, pinned on the Elixir side by
// "the emitted key set is PINNED — the Go reader decodes every key" in
// deploy_ledger_test.exs. The two pins are the contract: add a key there without
// adding it here and the Elixir test moves; add it here without a reader and the
// strict decode below fails.
//
// The numbers are the 40%-censored fixture the estimator refuses on: n=1000 with
// 400 rows still waiting, so p95 and max have no identifiable value and p50 does.
const censusDeliveryEnvelope = `{
  "window": {"from": "2026-08-01T00:00:00Z", "to": "2026-08-02T00:00:00Z"},
  "volume": 1000,
  "failed": 400,
  "failure_rate": {"sample": 1000, "pct": 40.0, "numerator": 400, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "delivery": {
    "window": {"from": "2026-08-01T00:00:00Z", "to": "2026-08-02T00:00:00Z", "width_seconds": 86400},
    "as_of": "2026-08-02T00:00:00Z",
    "environment": "production",
    "clock": "deployment row: inserted_at → became_live_at (row-keyed proxy; the publish-keyed clock lands with dr-w11-s1)",
    "sample": 1000,
    "delivered": 600,
    "p50": {"quantile": 0.5, "label": "p50", "seconds": 80.0, "sample": 1000, "censored": 400,
            "censored_fraction": 0.4, "headroom": 0.5, "window_seconds": 86400, "min_sample": 200,
            "refused": false, "reason": null, "basis": "floored: a still-waiting row contributes its lower bound"},
    "p95": {"quantile": 0.95, "label": "p95", "seconds": null, "sample": 1000, "censored": 400,
            "censored_fraction": 0.4, "headroom": 0.05, "window_seconds": 86400, "min_sample": 200,
            "refused": true,
            "reason": "p95 is UNIDENTIFIABLE: 40.0% are still waiting, exceeding the 5.0% headroom p95 needs",
            "basis": "floored: a still-waiting row contributes its lower bound"},
    "max": {"quantile": 1.0, "label": "max", "seconds": null, "sample": 1000, "censored": 400,
            "censored_fraction": 0.4, "headroom": 0.0, "window_seconds": 86400, "min_sample": 200,
            "refused": true,
            "reason": "max is UNIDENTIFIABLE: 40.0% are still waiting, exceeding the 0.0% headroom max needs",
            "basis": "floored: a still-waiting row contributes its lower bound"},
    "censored": {"count": 400, "as_of": "2026-08-02T00:00:00Z", "still_waiting_at_least_seconds": 76399.0},
    "unmetered": 7,
    "min_sample": 200,
    "sites": [
      {"site_id": "site-alpha", "sample": 1000, "delivered": 600, "censored": 400, "unmetered": 7,
       "still_waiting": true, "oldest_waiting_seconds": 76399.0, "as_of": "2026-08-02T00:00:00Z"},
      {"site_id": "jarl-website", "sample": 23, "delivered": 23, "censored": 0, "unmetered": 0,
       "still_waiting": false, "oldest_waiting_seconds": null, "as_of": "2026-08-02T00:00:00Z"}
    ]
  }
}`

// TestCloudDeploymentsDeliveryEveryEmittedKeyIsRead: the payload key-set guard.
// Every key `DeployLedger.delivery/3` emits decodes into a field this CLI reads —
// a strict decode (DisallowUnknownFields) fails on any key the Go side does not
// know, and the per-field assertions fail on any key that decodes into a field
// nobody looks at. A latency census whose reader silently drops half the payload
// is the same silence this epic exists to end.
func TestCloudDeploymentsDeliveryEveryEmittedKeyIsRead(t *testing.T) {
	var envelope struct {
		Delivery json.RawMessage `json:"delivery"`
	}
	if err := json.Unmarshal([]byte(censusDeliveryEnvelope), &envelope); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}

	dec := json.NewDecoder(bytes.NewReader(envelope.Delivery))
	dec.DisallowUnknownFields()
	var d cloudclient.DeployDelivery
	if err := dec.Decode(&d); err != nil {
		t.Fatalf("an emitted delivery key is UNREAD by cloudclient: %v", err)
	}

	if d.Window.From != "2026-08-01T00:00:00Z" || d.Window.To != "2026-08-02T00:00:00Z" || d.Window.WidthSeconds != 86400 {
		t.Fatalf("window decoded wrong: %+v", d.Window)
	}
	if d.AsOf != "2026-08-02T00:00:00Z" || d.Environment != "production" || !strings.Contains(d.Clock, "became_live_at") {
		t.Fatalf("as_of/environment/clock decoded wrong: %q %q %q", d.AsOf, d.Environment, d.Clock)
	}
	if d.Sample != 1000 || d.Delivered != 600 || d.Unmetered != 7 || d.MinSample != 200 {
		t.Fatalf("counts decoded wrong: sample=%d delivered=%d unmetered=%d min_sample=%d", d.Sample, d.Delivered, d.Unmetered, d.MinSample)
	}
	if d.P50.Seconds == nil || *d.P50.Seconds != 80.0 || d.P50.Refused {
		t.Fatalf("p50 decoded wrong: %+v", d.P50)
	}
	// The refusing node's `seconds` MUST stay nil — a float64 field would have
	// turned this null into 0.0s, the comforting zero in its purest form.
	if d.P95.Seconds != nil || !d.P95.Refused || d.P95.Headroom != 0.05 || d.P95.CensoredFraction != 0.4 ||
		d.P95.Quantile != 0.95 || d.P95.Label != "p95" || d.P95.Sample != 1000 || d.P95.Censored != 400 ||
		d.P95.WindowSeconds != 86400 || d.P95.MinSample != 200 || !strings.Contains(d.P95.Reason, "UNIDENTIFIABLE") ||
		!strings.Contains(d.P95.Basis, "floored") {
		t.Fatalf("p95 decoded wrong: %+v", d.P95)
	}
	if d.Max.Seconds != nil || !d.Max.Refused || d.Max.Quantile != 1.0 {
		t.Fatalf("max decoded wrong: %+v", d.Max)
	}
	if d.Censored.Count != 400 || d.Censored.AsOf != "2026-08-02T00:00:00Z" ||
		d.Censored.StillWaitingAtLeastSeconds == nil || *d.Censored.StillWaitingAtLeastSeconds != 76399.0 {
		t.Fatalf("censored cohort decoded wrong: %+v", d.Censored)
	}
	if len(d.Sites) != 2 {
		t.Fatalf("sites decoded wrong: %+v", d.Sites)
	}
	alpha, jarl := d.Sites[0], d.Sites[1]
	if alpha.SiteID != "site-alpha" || alpha.Sample != 1000 || alpha.Delivered != 600 || alpha.Censored != 400 ||
		alpha.Unmetered != 7 || !alpha.StillWaiting || alpha.OldestWaitingSeconds == nil ||
		*alpha.OldestWaitingSeconds != 76399.0 || alpha.AsOf != "2026-08-02T00:00:00Z" {
		t.Fatalf("site row decoded wrong: %+v", alpha)
	}
	// The jarl-website shape: live deliveries, nothing waiting — and its
	// oldest-waiting bound is ABSENT, not zero.
	if jarl.SiteID != "jarl-website" || jarl.StillWaiting || jarl.OldestWaitingSeconds != nil {
		t.Fatalf("a site with nothing waiting must carry a nil bound, never 0: %+v", jarl)
	}
}

// TestCloudDeploymentsDeliveryRefusesAndNamesWhoIsWaiting: the human render. The
// unidentifiable percentiles print NO NUMBER with the control plane's reason, the
// identifiable one prints beside its sample and window width, and the
// still-waiting cohort prints as a LOWER BOUND with an as-of — never as a count
// alone, and never as a duration of zero.
func TestCloudDeploymentsDeliveryRefusesAndNamesWhoIsWaiting(t *testing.T) {
	newCensusServer(t, 200, censusDeliveryEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 2, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-01", "--to", "2026-08-02")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	p95 := censusLineContaining(t, stdout, "p95 ")
	for _, want := range []string{
		"NO NUMBER",
		"p95 is UNIDENTIFIABLE: 40.0% are still waiting, exceeding the 5.0% headroom p95 needs",
		"n=1000", "400 still waiting", "window 24 hours",
	} {
		if !strings.Contains(p95, want) {
			t.Fatalf("p95 line %q missing %q — the refusal, its reason and its population ride the SAME line", p95, want)
		}
	}

	p50 := censusLineContaining(t, stdout, "p50 ")
	for _, want := range []string{"1m20s", "n=1000", "400 still waiting", "window 24 hours"} {
		if !strings.Contains(p50, want) {
			t.Fatalf("p50 line %q missing %q — a value may never travel without its population", p50, want)
		}
	}

	waiting := censusLineContaining(t, stdout, "STILL WAITING >=")
	for _, want := range []string{"STILL WAITING >= 21h13m19s", "400 row(s)", "(as of 2026-08-02T00:00:00Z)"} {
		if !strings.Contains(waiting, want) {
			t.Fatalf("still-waiting line %q missing %q — a bare count reports the measurement's own latency as fact", waiting, want)
		}
	}

	// dr-w15-s3: the OTHER arm must be gone. `renderDeployDelivery`'s `d == nil`
	// arm printed "NOT MEASURED — this control plane sends no delivery census" to
	// every operator forever, because nothing in cloud/lib called
	// `DeployLedger.delivery/3` and the census route emitted no `delivery` key.
	//
	// CORRECTED, dr-w21-s6. This comment used to read "The route emits it now
	// (`Web.Router.deploy_census_json/2`), so an envelope that CARRIES the node
	// must never render the sentence that says it doesn't" — and that was true
	// only of the OPERATOR route, `GET /v1/operator/deploy-ledger/census`, which
	// `require_platform_operator` answers `403 forbidden/platform_operator` to
	// every real account token. `bp cloud deployments` reads the TEAM route,
	// `GET /v1/deploy-ledger/census`, which carried NO `delivery` key at all, so
	// the only arm production ever executed was the one this check forbids: the
	// assertion below was green against a fixture this test builds itself while
	// the live plane printed "NOT MEASURED" to every operator. The team route
	// now emits a team-SCOPED `delivery` node (router.ex, dr-w21-s6), which is
	// what finally makes this fixture's shape the shape production sends. The
	// check itself is unchanged — it was never wrong about the RENDER, only
	// about which route had ever produced its input.
	if strings.Contains(stdout, "NOT MEASURED") {
		t.Fatalf("the delivery node is present, yet the render still claims it was not measured:\n%s", stdout)
	}

	if !strings.Contains(stdout, "clock: deployment row: inserted_at") {
		t.Fatalf("the clock must be printed beside the latency:\n%s", stdout)
	}
	if !strings.Contains(stdout, "7 row(s) the clock could not reach") {
		t.Fatalf("the unmetered cohort must be reported, never dropped:\n%s", stdout)
	}
	if !strings.Contains(stdout, "site-alpha") || !strings.Contains(stdout, "sites still waiting") {
		t.Fatalf("the still-waiting sites must be NAMED:\n%s", stdout)
	}
	// jarl-website has nothing waiting, so it must not appear in the
	// still-waiting list at all — and it must certainly not appear with a 0.
	if strings.Contains(stdout, "jarl-website") {
		t.Fatalf("a site with nothing waiting must not be listed as waiting:\n%s", stdout)
	}
	// No percentile anywhere rendered as a zero duration.
	if strings.Contains(stdout, ">= 0s") || strings.Contains(stdout, "p95  0") {
		t.Fatalf("a refused percentile or an unset bound rendered as zero:\n%s", stdout)
	}

	// dr-w15-s3 / charter D245: acceptance for the emit is a RUN, not an
	// assertion. Log what an operator actually sees so `go test -run
	// TestCloudDeploymentsDeliveryRefusesAndNamesWhoIsWaiting -v` IS the evidence,
	// rather than a green tick that proves only that a matcher matched.
	t.Logf("`bp cloud deployments` against a control plane that emits `delivery`:\n%s", stdout)
}

// TestCloudDeploymentsWithoutDeliverySaysNotMeasured: against TODAY's payload,
// which carries no `delivery` node at all, the reader says NOT MEASURED. Silence
// there would read as "delivery is fine", which is exactly the failure — silent
// and mis-reported — this epic exists to end.
func TestCloudDeploymentsWithoutDeliverySaysNotMeasured(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "NOT MEASURED")
	if !strings.Contains(line, "NOT a fleet that delivers instantly") {
		t.Fatalf("a missing delivery census must refuse out loud, not print nothing:\n%s", stdout)
	}
	if strings.Contains(stdout, "STILL WAITING") {
		t.Fatalf("nothing may be claimed about waiting when no delivery census was sent:\n%s", stdout)
	}
}
