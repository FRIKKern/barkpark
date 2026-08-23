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

// censusW12S8Envelope is what the control plane sends AFTER dr-w12-s8: the
// terminal rate at BOTH levels, the server's own `deferred_total`, and the
// abandonment COUNT with the size of its own blind spot beside it.
//
// The numbers are internally consistent on purpose — 832 failed + 591 live =
// 1423 terminal, and 2216 attempted - 1423 terminal = 793 deferred — so a render
// that mixes the two denominators up produces a number this fixture can catch.
const censusW12S8Envelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "live": 591,
  "deferred_total": 793,
  "abandoned": 6,
  "abandoned_unreadable": 0,
  "failure_rate": {"sample": 2216, "pct": 37.55, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "attempted rows (deferrals included)"},
  "terminal_failure_rate": {"sample": 1423, "pct": 58.47, "numerator": 832, "min_sample": 200, "refused": false, "reason": null, "basis": "TERMINAL rows only: failed + live"},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-alpha", "volume": 1200, "failed": 500, "deferred": 400, "live": 300,
     "failure_rate": {"sample": 1200, "pct": 41.67, "numerator": 500, "min_sample": 200, "refused": false, "reason": null},
     "terminal_failure_rate": {"sample": 800, "pct": 62.5, "numerator": 500, "min_sample": 200, "refused": false, "reason": null, "basis": "TERMINAL rows only: failed + live"},
     "top_class": "BOX_BUSY_409"}
  ],
  "min_sample": 200
}`

// TestCloudDeploymentsW12S8Payload: the control plane now sends what the reader
// has been declaring since dr-w8-s1, and the headline LEAVES its
// "older control plane" arm — the case the payload census's allowlist row named
// as the headline consequence of the emitter being unbuilt.
func TestCloudDeploymentsW12S8Payload(t *testing.T) {
	newCensusServer(t, 200, censusW12S8Envelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}

	// THE ARM IT MUST HAVE LEFT. This sentence is correct against today's
	// deployed CP and a LIE against a CP that sends the key, and nothing else in
	// the tree can tell the two apart.
	if strings.Contains(stdout, "this control plane sends no terminal-row rate") {
		t.Fatalf("the headline is still on its older-control-plane arm against a payload that carries the rate:\n%s", stdout)
	}
	headline := censusLineContaining(t, stdout, "of 2216 attempted")
	for _, want := range []string{"37.55%", "58.47% of 1423 terminal"} {
		if !strings.Contains(headline, want) {
			t.Fatalf("headline %q missing %q — both denominators ride the SAME line or a reader compares two screens", headline, want)
		}
	}

	// THE ABSOLUTE COUNT, beside the rates it cannot be reduced to.
	if !strings.Contains(stdout, "abandoned publishes: 6") {
		t.Fatalf("the abandonment COUNT is not on the census screen:\n%s", stdout)
	}

	// THE PER-SITE TWIN — the reader who asks "which site" must not be sent back
	// to the diluted column.
	site := censusLineContaining(t, stdout, "site-alpha")
	for _, want := range []string{"41.67%", "t 62.5%"} {
		if !strings.Contains(site, want) {
			t.Fatalf("site row %q missing %q — the per-site terminal rate did not render", site, want)
		}
	}
}

// TestDeployCensusAbandonmentThreeStates: absent, lower-bounded and exact are
// three DIFFERENT renders. Collapsing any two of them is the defect this pair of
// keys exists to make impossible, so it is asserted directly on the renderer
// rather than only through a whole-screen fixture.
func TestDeployCensusAbandonmentThreeStates(t *testing.T) {
	six, zero, four := 6, 0, 4

	cases := []struct {
		name    string
		census  cloudclient.DeployCensus
		want    string
		notWant string
	}{
		{
			name:    "not sent at all",
			census:  cloudclient.DeployCensus{},
			want:    "NOT COUNTED",
			notWant: "abandoned publishes: 0",
		},
		{
			name:    "a real zero",
			census:  cloudclient.DeployCensus{Abandoned: &zero, AbandonedUnreadable: &zero},
			want:    "abandoned publishes: 0",
			notWant: "LOWER BOUND",
		},
		{
			name:    "counted, and fully legible",
			census:  cloudclient.DeployCensus{Abandoned: &six, AbandonedUnreadable: &zero},
			want:    "abandoned publishes: 6",
			notWant: "LOWER BOUND",
		},
		{
			name:    "counted, with a blind spot beside it",
			census:  cloudclient.DeployCensus{Abandoned: &zero, AbandonedUnreadable: &four},
			want:    "LOWER BOUND",
			notWant: "NOT COUNTED",
		},
	}

	for _, tc := range cases {
		got := deployCensusAbandonment(tc.census)
		if !strings.Contains(got, tc.want) {
			t.Fatalf("%s: %q does not contain %q", tc.name, got, tc.want)
		}
		if strings.Contains(got, tc.notWant) {
			t.Fatalf("%s: %q must not contain %q — two of the three states have collapsed", tc.name, got, tc.notWant)
		}
	}

	// AND THE ZERO THAT IS A LOWER BOUND SAYS THE SIZE OF WHAT IT COULD NOT SEE.
	got := deployCensusAbandonment(cloudclient.DeployCensus{Abandoned: &zero, AbandonedUnreadable: &four})
	if !strings.Contains(got, "4 failed row(s) recorded no reason") {
		t.Fatalf("the blind spot's SIZE is missing: %q", got)
	}
}

// TestDeployCensusClassRowDecodesAndRendersAgency pins the dr-w31 fix:
// DeployLedger emits `agency` on every class row and it must (a) decode onto
// DeployCensusClass.Agency and (b) render as an "accuses:" cell — an older
// control plane that never sent the key renders "not sent", never an invented
// attribution. A struct edit that drops the `json:"agency"` tag (or a render
// edit that stops printing the cell) reds this test; proved by removing the
// tag and re-running, then restoring it.
func TestDeployCensusClassRowDecodesAndRendersAgency(t *testing.T) {
	const payload = `{"classes":[{"class":"BOX_UNREACHABLE","label":"box unreachable","count":9,"agency":"box","share":{"pct":42.0,"sample":21}}]}`

	var census cloudclient.DeployCensus
	if err := json.Unmarshal([]byte(payload), &census); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(census.Classes) != 1 {
		t.Fatalf("expected 1 class row, got %d", len(census.Classes))
	}
	if got := census.Classes[0].Agency; got != "box" {
		t.Fatalf("Agency decoded as %q, want %q — the field is silently dropped again", got, "box")
	}

	row := deployCensusClassRow(census.Classes[0])
	if !strings.Contains(row, "accuses: box") {
		t.Fatalf("class row %q does not render the agency cell", row)
	}

	// An older control plane sends no `agency` key at all — the render must
	// say so rather than inventing an attribution or printing an empty cell
	// that reads as a silent success.
	older := cloudclient.DeployCensusClass{Class: "OLD_CLASS", Label: "old", Count: 3}
	if got := deployCensusClassRow(older); !strings.Contains(got, "accuses: not sent") {
		t.Fatalf("a class row with no agency must render %q, got %q", "accuses: not sent", got)
	}
}

// TestDeployCensusCompletenessLineThreeStates: the census's own self-audit had
// been decoded since dr-w24 but rendered by nobody — this pins all three
// endings so the audit can never again ride the wire into silence.
func TestDeployCensusCompletenessLineThreeStates(t *testing.T) {
	if got := deployCensusCompletenessLine(nil); !strings.Contains(got, "NOT AUDITED") {
		t.Fatalf("nil completeness must say NOT AUDITED, got %q", got)
	}

	balanced := &cloudclient.DeployCensusCompleteness{
		Audited: 8383, Accounted: 8383, Unaccounted: 0, Balanced: true, Method: "cohort-sum",
	}
	if got := deployCensusCompletenessLine(balanced); !strings.Contains(got, "BALANCED") || !strings.Contains(got, "8383") {
		t.Fatalf("balanced completeness rendered wrong: %q", got)
	}

	reason := "3 rows in a cohort not yet named"
	unbalanced := &cloudclient.DeployCensusCompleteness{
		Audited: 100, Accounted: 97, Unaccounted: 3, Balanced: false, Method: "cohort-sum", Reason: &reason,
	}
	got := deployCensusCompletenessLine(unbalanced)
	if !strings.Contains(got, "NOT BALANCED") || !strings.Contains(got, "3 of 100") || !strings.Contains(got, reason) {
		t.Fatalf("unbalanced completeness rendered wrong: %q", got)
	}
}

// TestDeployCensusDeferredTotalPrefersTheServer: the client-side sum over the
// class rows is a SECOND definition of the number, and it is the one that can be
// confidently wrong — a control plane that sent no class rows makes it answer 0
// for a fleet that deferred hundreds.
func TestDeployCensusDeferredTotalPrefersTheServer(t *testing.T) {
	server := 793

	// The class rows and the server's own count DISAGREE on purpose: only a
	// reader that actually prefers the sent key can pass this.
	census := cloudclient.DeployCensus{
		DeferredTotal: &server,
		Deferred:      []cloudclient.DeployCensusClass{{Class: "BOX_BUSY_DEFERRED", Count: 11}},
	}
	if got := deployCensusDeferredTotal(census); got != server {
		t.Fatalf("deferred total = %d, want the server's own %d — the client-side sum won", got, server)
	}

	// …and a control plane that predates the key still gets the sum rather than a
	// silent zero.
	older := cloudclient.DeployCensus{
		Deferred: []cloudclient.DeployCensusClass{{Class: "BOX_BUSY_DEFERRED", Count: 11}, {Class: "DEFERRED_UNCLASSIFIED", Count: 4}},
	}
	if got := deployCensusDeferredTotal(older); got != 15 {
		t.Fatalf("deferred total = %d on a pre-key control plane, want the class sum 15", got)
	}
}

// TestDeployCensusSiteTerminalAbsence: a site whose control plane does not send
// the per-site terminal rate must render a MARK, never a blank column — a blank
// reads as 0% to a scanning eye, which is the flattering direction.
func TestDeployCensusSiteTerminalAbsence(t *testing.T) {
	if got := deployCensusSiteTerminal(cloudclient.DeployCensusSite{}); !strings.Contains(got, "—") {
		t.Fatalf("absent per-site terminal rate rendered %q, want a dash", got)
	}
	pct := 62.5
	sent := cloudclient.DeployCensusSite{
		TerminalFailureRate: &cloudclient.DeployRate{Sample: 800, Pct: &pct, Numerator: 500, MinSample: 200},
	}
	if got := deployCensusSiteTerminal(sent); !strings.Contains(got, "62.5%") {
		t.Fatalf("per-site terminal rate rendered %q, want the percentage", got)
	}
}

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
	for _, want := range []string{"37.55%", "832 failed", "793 deferred", "ATTEMPTED"} {
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
	for _, want := range []string{"37.55%", "832 failed", "793 deferred", "591 live", "58.47% of 1423 terminal"} {
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
//
// It also fails when MORE THAN ONE line carries the needle. Returning the first
// of several is a needle-hijack: a term that leaks onto its own line produces a
// second match, the helper hands back whichever renders first, and the caller's
// failure reads as a want-list problem on the wrong line — the exact misdirection
// dr-w16-s5 measured. One needle, one line, or the helper says why not.
func censusLineContaining(t *testing.T, out, needle string) string {
	t.Helper()
	var matches []string
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, needle) {
			matches = append(matches, line)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0]
	case 0:
		t.Fatalf("no line contains %q:\n%s", needle, out)
	default:
		t.Fatalf("needle hijack: %d lines contain %q — the needle no longer names ONE line, and asserting against the first would misread the render:\n%s\nfull output:\n%s",
			len(matches), needle, strings.Join(matches, "\n"), out)
	}
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
		"live 26.67% of 2216 attempted", "failure 37.55% of 2216 attempted",
		"832 failed", "793 deferred", "591 live", "58.47% of 1423 terminal",
		"9 in flight", "4 cancelled", "0 residual",
	} {
		if !strings.Contains(headline, want) {
			t.Fatalf("headline %q missing %q — live-per-attempt is co-equal and rides the SAME line", headline, want)
		}
	}
	if strings.Index(headline, "live 26.67%") > strings.Index(headline, "failure 37.55%") {
		t.Fatalf("the live rate must LEAD, not trail the failure rate: %q", headline)
	}
	// ONE line carries the denominator phrase — enforced by censusLineContaining
	// itself, which fails on more than one match, so the bespoke count that used
	// to live here is retired.
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
	// The envelope's pct renders VERBATIM (dr-w8-s4 followup): 25.0 on the
	// wire is the number 25, so the shortest-form render is "25%", never a
	// re-derived "25.0%".
	if !strings.HasPrefix(head, "live 25% of 12 attempted") {
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
// which reads as ATTEMPTS; it is rows, and an attempt that coalesces onto an
// in-flight build mints no row at all, so every rate above it is a ceiling. The
// line prints on EVERY payload, including the one that sends no basis of its
// own.
//
// THE SIZE OF THE CORRECTION IS NO LONGER FROZEN. This line used to append the
// literal "(measured 2026-08-06: 3,766 auto-deploy worker jobs against 2,182
// rows — 1,584 attempts excluded)" on every render regardless of window, and
// these assertions pinned it. It was not wrong; it was WINDOW-INDEPENDENT, which
// is its own kind of untrue on the other six windows. It is replaced by the
// window's own measurement or the producer's own refusal, asserted below and in
// TestCloudDeploymentsCoalescedAttemptsHonourRefusal.
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
			wantIn: []string{"attempted rows (deferrals included)", "deployment ROWS, not attempts", "CEILING"},
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
			// THE FROZEN-LITERAL GUARD, on rendered bytes. Neither envelope
			// carries a `coalesced_attempts` node, so the only way a date-stamped
			// count can reach this screen is a hardcode. It reds the moment one
			// is reintroduced in ANY wording, because it matches the SHAPE
			// ("measured <ISO date>: <count>") rather than the sentence.
			if m := frozenCountRe.FindString(basis); m != "" {
				t.Fatalf("a date-stamped count is hardcoded into the basis line (%q) — this window did not measure it: %q", m, basis)
			}
		})
	}
}

// frozenCountRe matches a count quoted against a fixed calendar date — the
// shape of the literal dr-w23-s4 deleted ("measured 2026-08-06: 3,766 …
// 1,584 attempts excluded"). A number a reader takes as this window's must come
// from this window's envelope; a number stamped with someone else's day is a
// claim no render can check.
var frozenCountRe = regexp.MustCompile(`measured \d{4}-\d{2}-\d{2}: *[\d,]+`)

// censusCoalescedMeasuredEnvelope carries the dr-w23-s4 gauge with a REAL count:
// a window wholly after the counter's coverage floor, so the producer measures
// rather than refuses.
const censusCoalescedMeasuredEnvelope = `{
  "window": {"from": "2026-08-07T12:00:00Z", "to": "2026-08-08T00:00:00Z"},
  "volume": 41,
  "failed": 2,
  "failure_rate": {"sample": 41, "pct": null, "numerator": 2, "min_sample": 200, "refused": true, "reason": "sample 41 below min_sample 200"},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "coalesced_attempts": {
    "value": 17,
    "refused": false,
    "reason": null,
    "since": "2026-08-07T10:02:23Z",
    "basis": "attempts that minted NO deployment row (AutoDeployWorker coalesced them onto an in-flight build) — DISJOINT from ` + "`volume`" + `, never folded into it"
  }
}`

// censusCoalescedRefusedEnvelope is the SAME gauge over a window that starts
// before the counter existed. `value` is null and `refused` is true: every
// pre-migration row carries a materialised 0 rather than a NULL, so a SUM here
// would report a confident zero for a day whose true coalesced volume ran into
// the thousands.
const censusCoalescedRefusedEnvelope = `{
  "window": {"from": "2026-08-06T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2182,
  "failed": 25,
  "failure_rate": {"sample": 2182, "pct": 1.15, "numerator": 25, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "coalesced_attempts": {
    "value": null,
    "refused": true,
    "reason": "the coalesced-attempt counter did not exist before 2026-08-07T10:02:23Z (migration 20260807150000). Every earlier row carries a materialised default of 0, not a NULL, so a SUM over this window would report a confident 0 — it read 0 for 2026-08-06, a day whose true coalesced volume was ~1,563",
    "since": "2026-08-07T10:02:23Z",
    "basis": "attempts that minted NO deployment row (AutoDeployWorker coalesced them onto an in-flight build) — DISJOINT from ` + "`volume`" + `, never folded into it"
  }
}`

// TestCloudDeploymentsCoalescedAttemptsHonourRefusal: the gauge renders in
// `-o table` with all THREE of its endings, and the refusal is the one that
// matters. Before this slice the key rode the wire and reached `-o json` only
// because `-o json` re-emits the envelope verbatim — no Go struct named it, so
// the human render could not show it at any price.
//
// A renderer that printed `0` for the refused node would manufacture exactly the
// confidence the producer declined to manufacture, which is why the refused arm
// asserts the ABSENCE of a count as hard as the measured arm asserts its
// presence.
func TestCloudDeploymentsCoalescedAttemptsHonourRefusal(t *testing.T) {
	t.Run("measured: the window's OWN number, on the basis line", func(t *testing.T) {
		newCensusServer(t, 200, censusCoalescedMeasuredEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 8, 0, 0, 0, 0, time.UTC))

		stdout, stderr, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		basis := censusLineContaining(t, stdout, "basis:")
		for _, want := range []string{"Coalesced attempts measured over THIS window: 17", "DISJOINT from"} {
			if !strings.Contains(basis, want) {
				t.Fatalf("basis line %q missing %q — the measured count and what it counts must travel together", basis, want)
			}
		}
		if strings.Contains(basis, "NOT MEASURED") {
			t.Fatalf("a measured gauge must not also claim it was not measured: %q", basis)
		}
		t.Logf("`bp cloud deployments` basis line, gauge MEASURED:\n%s", basis)
	})

	t.Run("refused: a reason and NO number, never a zero", func(t *testing.T) {
		newCensusServer(t, 200, censusCoalescedRefusedEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

		stdout, stderr, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		basis := censusLineContaining(t, stdout, "basis:")
		for _, want := range []string{
			"Coalesced attempts NOT MEASURED for this window",
			"did not exist before 2026-08-07T10:02:23Z",
			"materialised default of 0",
		} {
			if !strings.Contains(basis, want) {
				t.Fatalf("basis line %q missing %q — a refusal must carry the producer's own reason", basis, want)
			}
		}
		// THE COMFORTING ZERO, forbidden in every wording a refused count could
		// wear. `measured over THIS window: 0` is the shape a nil-coalescing
		// decoder would print.
		if strings.Contains(basis, "measured over THIS window") {
			t.Fatalf("a REFUSED gauge rendered as a measurement: %q", basis)
		}
		t.Logf("`bp cloud deployments` basis line, gauge REFUSED:\n%s", basis)
	})

	t.Run("not sent: an absence, named", func(t *testing.T) {
		newCensusServer(t, 200, censusTodayEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

		stdout, _, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0", code)
		}
		basis := censusLineContaining(t, stdout, "basis:")
		if !strings.Contains(basis, "Coalesced attempts NOT MEASURED: this control plane sends no coalesced-attempt counter") {
			t.Fatalf("an absent gauge must be named absent, never omitted: %q", basis)
		}
		if !strings.Contains(basis, "it is not zero") {
			t.Fatalf("an absence must say what it is NOT, or it reads as a zero: %q", basis)
		}
	})

	t.Run("the decoder actually decodes it", func(t *testing.T) {
		var census cloudclient.DeployCensus
		if err := json.Unmarshal([]byte(censusCoalescedMeasuredEnvelope), &census); err != nil {
			t.Fatalf("fixture does not decode: %v", err)
		}
		if census.CoalescedAttempts == nil || census.CoalescedAttempts.Value == nil {
			t.Fatalf("coalesced_attempts did not decode into a typed field: %+v", census.CoalescedAttempts)
		}
		if *census.CoalescedAttempts.Value != 17 || census.CoalescedAttempts.Since != "2026-08-07T10:02:23Z" {
			t.Fatalf("decoded gauge is wrong: %+v", *census.CoalescedAttempts)
		}
		var refused cloudclient.DeployCensus
		if err := json.Unmarshal([]byte(censusCoalescedRefusedEnvelope), &refused); err != nil {
			t.Fatalf("refused fixture does not decode: %v", err)
		}
		// The load-bearing decode: `null` must arrive as nil, not as 0.
		if refused.CoalescedAttempts == nil || !refused.CoalescedAttempts.Refused || refused.CoalescedAttempts.Value != nil {
			t.Fatalf("a refused gauge must decode with NO value: %+v", refused.CoalescedAttempts)
		}
	})
}

// censusCapacitySplitEnvelope carries the SAME physical cause in both cohorts,
// at the live proportions measured over 2026-08-07T00:00–06:00Z: six capacity
// abandonments inside the failure numerator, 719 capacity deferrals outside it.
const censusCapacitySplitEnvelope = `{
  "window": {"from": "2026-08-07T00:00:00Z", "to": "2026-08-07T06:00:00Z"},
  "volume": 965,
  "failed": 14,
  "failure_rate": {"sample": 965, "pct": 1.45, "numerator": 14, "min_sample": 200, "refused": false, "reason": null},
  "classes": [
    {"class": "ABANDONED_AT_CAPACITY", "label": "the box was full and the publish was abandoned", "count": 6,
     "share": {"sample": 14, "pct": 42.86, "numerator": 6, "min_sample": 200, "refused": false, "reason": null}},
    {"class": "DOC_ID_EMPTY", "label": "the cause went unrecorded", "count": 8,
     "share": {"sample": 14, "pct": 57.14, "numerator": 8, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "deferred": [
    {"class": "BOX_AT_CAPACITY_DEFERRED", "label": "the box was at capacity; re-queued", "count": 719,
     "share": {"sample": 965, "pct": 74.51, "numerator": 719, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200
}`

// TestCloudDeploymentsCapacityCrossReference: one cause, two cohorts, and now
// ONE line that says so — with both counts, on the rendered screen.
//
// It is a cross-reference and NOT a re-classification: ABANDONED_AT_CAPACITY
// stays in the failure classes and BOX_AT_CAPACITY_DEFERRED stays in the
// deferrals, exactly as the control plane sent them. Whether an abandoned
// publish belongs in the failure numerator is a judgment this reader does not
// make — asserted below by checking both rows still render in their own cohorts
// with their own counts.
func TestCloudDeploymentsCapacityCrossReference(t *testing.T) {
	newCensusServer(t, 200, censusCapacitySplitEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 6, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "box capacity is ONE cause reported through TWO cohorts")
	for _, want := range []string{"ABANDONED_AT_CAPACITY 6", "BOX_AT_CAPACITY_DEFERRED 719", "INSIDE the failure numerator", "OUTSIDE it"} {
		if !strings.Contains(line, want) {
			t.Fatalf("cross-reference line %q missing %q — both counts and both sides of the numerator must ride it", line, want)
		}
	}
	// NOTHING MOVED. Both rows still render inside their own cohort, under their
	// own heading, with their own counts.
	failures := censusSectionAfter(t, stdout, "failure classes")
	if !strings.Contains(failures, "ABANDONED_AT_CAPACITY") {
		t.Fatalf("the abandoned rows left the failure classes — this slice re-classified something:\n%s", stdout)
	}
	deferrals := censusSectionAfter(t, stdout, "deferrals (in the volume")
	if !strings.Contains(deferrals, "BOX_AT_CAPACITY_DEFERRED") {
		t.Fatalf("the deferred rows left the deferral cohort — this slice re-classified something:\n%s", stdout)
	}
	t.Logf("`bp cloud deployments` against a window whose capacity refusals split across cohorts:\n%s", stdout)

	// AND IT CAN LOSE: with both counts zero, the line is ABSENT. A
	// cross-reference to two cohorts this window did not have would assert a
	// split that did not happen.
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))
	quiet, _, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if strings.Contains(quiet, "ONE cause reported through TWO cohorts") {
		t.Fatalf("the cross-reference line printed for a window with neither capacity cohort:\n%s", quiet)
	}
}

// censusSectionAfter returns the rendered block that starts at the heading
// containing `heading` and ends at the next blank line — so an assertion about
// "the failure classes" is taken against the failure classes and not against
// any line that happens to name the same class elsewhere on the screen.
func censusSectionAfter(t *testing.T, out, heading string) string {
	t.Helper()
	lines := strings.Split(out, "\n")
	for i, line := range lines {
		if !strings.Contains(line, heading) {
			continue
		}
		var section []string
		for _, l := range lines[i:] {
			if strings.TrimSpace(l) == "" && len(section) > 0 {
				break
			}
			section = append(section, l)
		}
		return strings.Join(section, "\n")
	}
	t.Fatalf("no section headed %q:\n%s", heading, out)
	return ""
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

	// The per-site rows (dr-w23-s2) also carry "STILL WAITING >=", so the fleet
	// line is named by its own phrase — the hardened helper reds a bare needle.
	waiting := censusLineContaining(t, stdout, "row(s) not delivered")
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
	//
	// dr-w29-s2: the needle is now the DELIVERY sentence specifically. The
	// section above this one (the deferral wait) has its own NOT MEASURED arm and
	// this fixture carries no `deferral_wait` node, so a bare "NOT MEASURED"
	// substring would fire on a sentence about a different census entirely. The
	// check is unchanged in intent: a present delivery node may never render the
	// sentence that says delivery was not measured.
	//
	// dr-w23-s4 makes that concern concrete rather than hypothetical: the
	// coalesced-attempt gauge on the basis line renders its own honest absence
	// with the same two words, so the narrowed needle is now load-bearing against
	// a real second refusal, not just a foreseeable one.
	if strings.Contains(stdout, "NOT MEASURED — this control plane sends no delivery census") {
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
	// dr-w29-s2: pinned to the DELIVERY sentence — the deferral-wait section,
	// which renders first and is also absent from this payload, has a NOT
	// MEASURED sentence of its own.
	// dr-w23-s4 added a second, real one: the coalesced-attempt gauge's refusal
	// on the basis line. censusLineContaining now FAILS on a multi-match, so a
	// bare "NOT MEASURED" needle would red as a hijack instead of silently
	// asserting against another section — the specific sentence keeps it to one.
	line := censusLineContaining(t, stdout, "NOT MEASURED — this control plane sends no delivery census")
	if !strings.Contains(line, "NOT a population that delivers instantly") {
		t.Fatalf("a missing delivery census must refuse out loud, not print nothing:\n%s", stdout)
	}
	if strings.Contains(stdout, "STILL WAITING") {
		t.Fatalf("nothing may be claimed about waiting when no delivery census was sent:\n%s", stdout)
	}
}

// censusDeferralWaitEnvelope is the dr-w28-s4 / #11207 payload: the census PLUS
// `deferral_wait`, the clock the `deferred` COUNT never had.
//
// The numbers are the shape a SHORT window really sends, and they are chosen to
// expose the mask: `sample` 23 sits below p95's `min_sample` 200, and the
// server's `cond` tests that FIRST, so `reason` says only "sample 23 below
// min_sample 200" — while the very same node carries `unresolved_fraction`
// 0.2581 against p95's 0.05 `headroom`, 5.2x over. A renderer that prints Reason
// alone reports a small-sample problem and hides an identifiability one.
//
// p50 carries a value (min_sample 20, met) so the value branch renders too, and
// `max` refuses with 11 rows PENDING, which is what puts a censored lower bound
// in max's place.
const censusDeferralWaitEnvelope = `{
  "window": {"from": "2026-08-09T11:00:00Z", "to": "2026-08-09T12:00:00Z"},
  "volume": 60,
  "failed": 12,
  "failure_rate": {"sample": 60, "pct": 20.0, "numerator": 12, "min_sample": 200, "refused": true, "reason": "sample 60 below min_sample 200"},
  "classes": [],
  "deferred": [
    {"class": "BOX_BUSY_DEFERRED", "label": "the box was busy; re-queued", "count": 34,
     "share": {"sample": 60, "pct": 56.7, "numerator": 34, "min_sample": 200, "refused": true, "reason": "sample 60 below min_sample 200"}}
  ],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "deferral_wait": {
    "clock": "deferred row: inserted_at → the first later-MINTED live build on the same site and environment (time-keyed, never content_rev)",
    "basis": "floored: a pending re-queue contributes its lower bound",
    "as_of": "2026-08-09T12:00:00Z",
    "population": {"deferred": 34, "covered": 23, "pending": 11, "unreadable": 0},
    "outcomes": [
      {"outcome": "covered", "label": "the site has since rebuilt", "count": 23},
      {"outcome": "pending", "label": "no later live build exists yet", "count": 11},
      {"outcome": "unreadable", "label": "the row carries no readable re-queue", "count": 0}
    ],
    "sample": 23,
    "unresolved": 11,
    "oldest_pending_seconds": 379.3,
    "p50": {"quantile": 0.5, "label": "p50", "seconds": 241.14, "sample": 23, "unresolved": 11,
            "unresolved_fraction": 0.2581, "headroom": 0.5, "min_sample": 20, "refused": false,
            "reason": null, "basis": "floored: a pending re-queue contributes its lower bound"},
    "p95": {"quantile": 0.95, "label": "p95", "seconds": null, "sample": 23, "unresolved": 11,
            "unresolved_fraction": 0.2581, "headroom": 0.05, "min_sample": 200, "refused": true,
            "reason": "sample 23 below min_sample 200",
            "basis": "floored: a pending re-queue contributes its lower bound"},
    "max": {"quantile": 1.0, "label": "max", "seconds": null, "sample": 23, "unresolved": 11,
            "unresolved_fraction": 0.2581, "headroom": 0.0, "min_sample": 200, "refused": true,
            "reason": "max is UNIDENTIFIABLE: 25.81% are unresolved, exceeding the 0.0% headroom max needs",
            "basis": "floored: a pending re-queue contributes its lower bound"},
    "min_sample": 200
  }
}`

// censusDeferralWaitUnreadableEnvelope is THE HOLE, made reproducible: the
// unresolved mass is entirely UNREADABLE. pending is 0, so
// `oldest_pending_seconds` is null — there is no wait still running to bound —
// yet `max` still refuses, because unreadable rows are unresolved. A renderer
// that says "max refused, therefore print the censored bound" prints an EMPTY
// CELL here: a fresh silent mis-report inside the section built to end them.
const censusDeferralWaitUnreadableEnvelope = `{
  "window": {"from": "2026-08-02T00:00:00Z", "to": "2026-08-09T00:00:00Z"},
  "volume": 3200,
  "failed": 40,
  "failure_rate": {"sample": 3200, "pct": 1.25, "numerator": 40, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "deferral_wait": {
    "clock": "deferred row: inserted_at → the first later-MINTED live build on the same site and environment (time-keyed, never content_rev)",
    "basis": "floored: a pending re-queue contributes its lower bound",
    "as_of": "2026-08-09T00:00:00Z",
    "population": {"deferred": 3138, "covered": 3132, "pending": 0, "unreadable": 6},
    "outcomes": [
      {"outcome": "covered", "label": "the site has since rebuilt", "count": 3132},
      {"outcome": "pending", "label": "no later live build exists yet", "count": 0},
      {"outcome": "unreadable", "label": "the row carries no readable re-queue", "count": 6}
    ],
    "sample": 3132,
    "unresolved": 6,
    "oldest_pending_seconds": null,
    "p50": {"quantile": 0.5, "label": "p50", "seconds": 241.14, "sample": 3132, "unresolved": 6,
            "unresolved_fraction": 0.0019, "headroom": 0.5, "min_sample": 200, "refused": false,
            "reason": null, "basis": "floored: a pending re-queue contributes its lower bound"},
    "p95": {"quantile": 0.95, "label": "p95", "seconds": 6793.6, "sample": 3132, "unresolved": 6,
            "unresolved_fraction": 0.0019, "headroom": 0.05, "min_sample": 200, "refused": false,
            "reason": null, "basis": "floored: a pending re-queue contributes its lower bound"},
    "max": {"quantile": 1.0, "label": "max", "seconds": null, "sample": 3132, "unresolved": 6,
            "unresolved_fraction": 0.0019, "headroom": 0.0, "min_sample": 200, "refused": true,
            "reason": "max is UNIDENTIFIABLE: 0.19% are unresolved, exceeding the 0.0% headroom max needs",
            "basis": "floored: a pending re-queue contributes its lower bound"},
    "min_sample": 200
  }
}`

// TestCloudDeploymentsDeferralWaitEveryEmittedKeyIsRead: the payload key-set
// guard for `deferral_wait`. A strict decode (DisallowUnknownFields) fails on any
// key the Go side does not know, and the per-field assertions below fail on any
// key that decodes into a field nobody reads. Decode is NOT readership: this
// node shipped in #11207, decoded at internal/cloudclient/client.go, and was
// rendered to nobody until this slice.
func TestCloudDeploymentsDeferralWaitEveryEmittedKeyIsRead(t *testing.T) {
	var envelope struct {
		DeferralWait json.RawMessage `json:"deferral_wait"`
	}
	if err := json.Unmarshal([]byte(censusDeferralWaitEnvelope), &envelope); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}

	dec := json.NewDecoder(bytes.NewReader(envelope.DeferralWait))
	dec.DisallowUnknownFields()
	var w cloudclient.DeployDeferralWait
	if err := dec.Decode(&w); err != nil {
		t.Fatalf("an emitted deferral_wait key is UNREAD by cloudclient: %v", err)
	}

	if !strings.Contains(w.Clock, "first later-MINTED live build") || !strings.Contains(w.Basis, "floored") ||
		w.AsOf != "2026-08-09T12:00:00Z" {
		t.Fatalf("clock/basis/as_of decoded wrong: %q %q %q", w.Clock, w.Basis, w.AsOf)
	}
	if w.Population.Deferred != 34 || w.Population.Covered != 23 || w.Population.Pending != 11 || w.Population.Unreadable != 0 {
		t.Fatalf("population decoded wrong: %+v", w.Population)
	}
	if w.Sample != 23 || w.Unresolved != 11 || w.MinSample != 200 {
		t.Fatalf("counts decoded wrong: sample=%d unresolved=%d min_sample=%d", w.Sample, w.Unresolved, w.MinSample)
	}
	if w.OldestPendingSeconds == nil || *w.OldestPendingSeconds != 379.3 {
		t.Fatalf("oldest_pending_seconds decoded wrong: %v", w.OldestPendingSeconds)
	}
	if len(w.Outcomes) != 3 {
		t.Fatalf("outcomes decoded wrong: %+v", w.Outcomes)
	}
	for i, want := range []cloudclient.DeployDeferralWaitOutcome{
		{Outcome: "covered", Label: "the site has since rebuilt", Count: 23},
		{Outcome: "pending", Label: "no later live build exists yet", Count: 11},
		{Outcome: "unreadable", Label: "the row carries no readable re-queue", Count: 0},
	} {
		if w.Outcomes[i] != want {
			t.Fatalf("outcome %d decoded wrong: %+v, want %+v", i, w.Outcomes[i], want)
		}
	}
	if w.P50.Seconds == nil || *w.P50.Seconds != 241.14 || w.P50.Refused || w.P50.Quantile != 0.5 ||
		w.P50.Label != "p50" || w.P50.Sample != 23 || w.P50.Unresolved != 11 ||
		w.P50.UnresolvedFraction != 0.2581 || w.P50.Headroom != 0.5 || w.P50.MinSample != 20 ||
		!strings.Contains(w.P50.Basis, "floored") {
		t.Fatalf("p50 decoded wrong: %+v", w.P50)
	}
	// The refusing nodes' `seconds` MUST stay nil — a float64 field would have
	// turned these nulls into 0.0s: a fleet whose re-queues look instant because
	// nobody could measure them.
	if w.P95.Seconds != nil || !w.P95.Refused || w.P95.Headroom != 0.05 || w.P95.UnresolvedFraction != 0.2581 ||
		w.P95.Quantile != 0.95 || w.P95.Label != "p95" || w.P95.MinSample != 200 ||
		w.P95.Reason != "sample 23 below min_sample 200" {
		t.Fatalf("p95 decoded wrong: %+v", w.P95)
	}
	if w.Max.Seconds != nil || !w.Max.Refused || w.Max.Quantile != 1.0 || w.Max.Headroom != 0.0 ||
		!strings.Contains(w.Max.Reason, "UNIDENTIFIABLE") {
		t.Fatalf("max decoded wrong: %+v", w.Max)
	}
}

// TestCloudDeploymentsDeferralWaitRefusesAndKeepsItsPopulation: the human
// render, asserted on RENDERED BYTES. The Elixir payload-key census's render arm
// is a text scan and greens a render that does not even compile, so the proof
// that a human sees this has to be stdout.
//
// Everything about one quantile rides ONE line: the refusal token, the control
// plane's reason VERBATIM, the identifiability facts BESIDE it (which is the
// whole point — the reason names only the small sample) and the population it
// was taken over, with its as-of.
func TestCloudDeploymentsDeferralWaitRefusesAndKeepsItsPopulation(t *testing.T) {
	newCensusServer(t, 200, censusDeferralWaitEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-09T11:00:00Z", "--to", "2026-08-09T12:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	p95 := censusLineContaining(t, stdout, "p95 ")
	for _, want := range []string{
		"NO NUMBER",
		"sample 23 below min_sample 200",
		// The mask, broken: the reason names only the small sample, the line
		// says unidentifiable as well.
		"unresolved 11 = 25.81% vs headroom 5.00%",
		"n=23", "covered 23 / pending 11 / unreadable 0 of 34 deferred · as of 2026-08-09T12:00:00Z",
	} {
		if !strings.Contains(p95, want) {
			t.Fatalf("p95 line %q missing %q — the refusal, its reason, its identifiability and its population ride the SAME line", p95, want)
		}
	}

	p50 := censusLineContaining(t, stdout, "p50 ")
	for _, want := range []string{"4m1s", "unresolved 11 = 25.81% vs headroom 50.00%", "covered 23 / pending 11 / unreadable 0 of 34 deferred"} {
		if !strings.Contains(p50, want) {
			t.Fatalf("p50 line %q missing %q — a value may never travel without its population", p50, want)
		}
	}

	// max refuses on an OPEN window, and its refusal carries the censored lower
	// bound on the waits that are still running — on the SAME line.
	maxLine := censusLineContaining(t, stdout, "max ")
	for _, want := range []string{
		"NO NUMBER",
		"max is UNIDENTIFIABLE: 25.81% are unresolved, exceeding the 0.0% headroom max needs",
		"STILL WAITING >= 6m19s", "11 row(s) not covered", "(as of 2026-08-09T12:00:00Z)",
	} {
		if !strings.Contains(maxLine, want) {
			t.Fatalf("max line %q missing %q — a refused max must state the bound on the waits still running", maxLine, want)
		}
	}

	// The control plane's own words for every cohort, and the zero counter with
	// its denominator: `unreadable` is 0 over 34 deferred and still prints.
	for _, want := range []string{
		"the site has since rebuilt",
		"no later live build exists yet",
		"the row carries no readable re-queue",
		"clock: deferred row: inserted_at",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the render dropped %q — outcome labels are the control plane's words, never a gloss:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "NOT MEASURED — this control plane sends no deferral-wait census") {
		t.Fatalf("the deferral_wait node is present, yet the render claims it was not measured:\n%s", stdout)
	}
	// Negative assertions: nothing rendered as a comforting zero, and no
	// quantile appeared as a bare number.
	if strings.Contains(stdout, ">= 0s") || strings.Contains(stdout, "p95  0") || strings.Contains(stdout, "max  0") {
		t.Fatalf("a refused quantile or an unset bound rendered as zero:\n%s", stdout)
	}

	// charter D245: acceptance for the emit is a RUN. This log IS the evidence.
	t.Logf("`bp cloud deployments` against a control plane that emits `deferral_wait`:\n%s", stdout)
}

// TestCloudDeploymentsDeferralWaitUnreadableMassNeverPrintsAnEmptyCell: THE HOLE.
// pending 0 and unreadable 6 means max refuses AND there is no pending wait to
// bound, so `oldest_pending_seconds` is null. The bound's place must carry the
// UNREADABLE count with the control plane's own label — never an empty cell,
// never a 0s.
func TestCloudDeploymentsDeferralWaitUnreadableMassNeverPrintsAnEmptyCell(t *testing.T) {
	newCensusServer(t, 200, censusDeferralWaitUnreadableEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-02", "--to", "2026-08-09")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	maxLine := censusLineContaining(t, stdout, "max ")
	for _, want := range []string{
		"NO NUMBER",
		"NO BOUND — nothing is pending, yet 6 row(s) are UNREADABLE (the row carries no readable re-queue)",
		"covered 3132 / pending 0 / unreadable 6 of 3138 deferred",
		"(as of 2026-08-09T00:00:00Z)",
	} {
		if !strings.Contains(maxLine, want) {
			t.Fatalf("max line %q missing %q — an unresolved mass that is entirely UNREADABLE must still be named", maxLine, want)
		}
	}
	if strings.Contains(maxLine, "STILL WAITING") {
		t.Fatalf("nothing is pending, so no wait may be claimed to be still running: %q", maxLine)
	}
	if strings.Contains(stdout, ">= 0s") {
		t.Fatalf("an absent bound rendered as zero:\n%s", stdout)
	}

	p95 := censusLineContaining(t, stdout, "p95 ")
	if !strings.Contains(p95, "1h53m14s") || !strings.Contains(p95, "covered 3132 / pending 0 / unreadable 6 of 3138 deferred") {
		t.Fatalf("p95 line %q must carry its value AND its population", p95)
	}

	t.Logf("`bp cloud deployments` when the unresolved mass is entirely UNREADABLE:\n%s", stdout)
}

// TestCloudDeploymentsWithoutDeferralWaitSaysNotMeasured: against a payload with
// no `deferral_wait` node (every control plane older than #11207), the reader
// says NOT MEASURED and claims nothing. Silence there reads as "deferrals are
// re-queued instantly", which is exactly the mis-report this epic exists to end:
// the `deferrals` block above is a COUNT WITH NO CLOCK.
func TestCloudDeploymentsWithoutDeferralWaitSaysNotMeasured(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "NOT MEASURED — this control plane sends no deferral-wait census")
	for _, want := range []string{"COUNT WITH NO CLOCK", "NOT a population that re-queues instantly"} {
		if !strings.Contains(line, want) {
			t.Fatalf("a missing deferral-wait census must refuse out loud:\n%s", stdout)
		}
	}
	// Nothing may be claimed: no quantile, no bound, no population.
	for _, forbidden := range []string{"STILL WAITING >= ", "NO BOUND", "deferred · as of"} {
		if strings.Contains(stdout, forbidden) {
			t.Fatalf("nothing may be claimed about the deferral wait when none was sent (%q):\n%s", forbidden, stdout)
		}
	}
	t.Logf("`bp cloud deployments` against a control plane older than #11207:\n%s", stdout)
}

// ─── THE COVERAGE PARTITION, OVER BOTH NEVER-LIVE COHORTS (dr-w32-s3) ────────
//
// The deferral wait above is a clock over `status == "deferred"` rows and
// NOTHING else, so a reader who took it as the coverage gauge was reading a
// number that structurally could not see the chains terminating `failed` — a
// third of the never-live tail on the corpus that motivated this key. The
// envelope below carries the shape the control plane emits: two cohorts, side by
// side, never summed.
const censusCoverageEnvelope = `{
  "window": {"from": "2026-08-09T11:00:00Z", "to": "2026-08-09T12:00:00Z"},
  "volume": 60,
  "failed": 12,
  "failure_rate": {"sample": 60, "pct": 20.0, "numerator": 12, "min_sample": 200, "refused": true, "reason": "sample 60 below min_sample 200"},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "coverage_cohorts": {
    "clock": "the SAME clock as deferral_wait, applied to BOTH cohorts",
    "basis": "COVERAGE, and only coverage: a row counts as COVERED when THE SITE has since rebuilt",
    "as_of": "2026-08-09T12:00:00Z",
    "maturity_seconds": 86400,
    "covering_bound": "left_only",
    "never_covered_sites": [
      {"site_id": "0f5f0a6e-2c1e-4a0f-9f2a-0c9f1d7a1111", "name": "Jarl Website", "slug": "jarl-website",
       "environment": "production", "never_covered": 3},
      {"site_id": "6b1f5c2d-9a44-4f21-b0d3-2a5e8c9f2222", "name": "Preview Box", "slug": "preview-box",
       "environment": "preview", "never_covered": 2}
    ],
    "never_covered_sites_total": 7,
    "never_covered_sites_truncated": true,
    "cohorts": [
      {"cohort": "deferred", "status": "deferred", "population": 2816, "covered": 2816,
       "pending": 0, "unreadable": 0, "matured": 2816, "never_covered": 0, "too_young": 0,
       "never_covered_by_environment": [], "oldest_pending_seconds": null},
      {"cohort": "failed", "status": "failed", "population": 18640, "covered": 18630,
       "pending": 10, "unreadable": 0, "matured": 18635, "never_covered": 5, "too_young": 5,
       "never_covered_by_environment": [
         {"environment": "production", "never_covered": 3},
         {"environment": "preview", "never_covered": 2}
       ],
       "oldest_pending_seconds": 913247.0}
    ]
  }
}`

// The SAME envelope as a control plane older than dr-w34-s1 sends it: the
// coverage node, with no covering_bound and no per-site breakdown at all. Held
// as its own literal rather than cut out of the one above, because a fixture
// built by string surgery breaks silently the moment the shape it cuts moves.
const censusCoverageEnvelopeWithoutSites = `{
  "window": {"from": "2026-08-09T11:00:00Z", "to": "2026-08-09T12:00:00Z"},
  "volume": 60,
  "failed": 12,
  "failure_rate": {"sample": 60, "pct": 20.0, "numerator": 12, "min_sample": 200, "refused": true, "reason": "sample 60 below min_sample 200"},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200,
  "coverage_cohorts": {
    "clock": "the SAME clock as deferral_wait, applied to BOTH cohorts",
    "basis": "COVERAGE, and only coverage: a row counts as COVERED when THE SITE has since rebuilt",
    "as_of": "2026-08-09T12:00:00Z",
    "maturity_seconds": 86400,
    "cohorts": [
      {"cohort": "deferred", "status": "deferred", "population": 2816, "covered": 2816,
       "pending": 0, "unreadable": 0, "matured": 2816, "never_covered": 0, "too_young": 0,
       "never_covered_by_environment": [], "oldest_pending_seconds": null},
      {"cohort": "failed", "status": "failed", "population": 18640, "covered": 18630,
       "pending": 10, "unreadable": 0, "matured": 18635, "never_covered": 5, "too_young": 5,
       "never_covered_by_environment": [
         {"environment": "production", "never_covered": 3},
         {"environment": "preview", "never_covered": 2}
       ],
       "oldest_pending_seconds": 913247.0}
    ]
  }
}`

// TestCloudDeploymentsCoverageEveryEmittedKeyIsRead: DisallowUnknownFields is
// the whole assertion. A key the control plane emits and cloudclient does not
// declare is a key the operator's terminal silently drops — which is exactly how
// a coverage gauge would ship green and show nobody anything.
func TestCloudDeploymentsCoverageEveryEmittedKeyIsRead(t *testing.T) {
	var envelope struct {
		CoverageCohorts json.RawMessage `json:"coverage_cohorts"`
	}
	if err := json.Unmarshal([]byte(censusCoverageEnvelope), &envelope); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}

	dec := json.NewDecoder(bytes.NewReader(envelope.CoverageCohorts))
	dec.DisallowUnknownFields()
	var c cloudclient.DeployCoverageCohorts
	if err := dec.Decode(&c); err != nil {
		t.Fatalf("an emitted coverage_cohorts key is UNREAD by cloudclient: %v", err)
	}

	if c.MaturitySeconds != 86400 || c.AsOf != "2026-08-09T12:00:00Z" ||
		!strings.Contains(c.Basis, "THE SITE has since rebuilt") {
		t.Fatalf("clock/basis/as_of/fence decoded wrong: %+v", c)
	}
	if len(c.Cohorts) != 2 {
		t.Fatalf("cohorts decoded wrong: %+v", c.Cohorts)
	}
	deferred, failed := c.Cohorts[0], c.Cohorts[1]
	if deferred.Cohort != "deferred" || deferred.Population != 2816 || deferred.NeverCovered != 0 {
		t.Fatalf("deferred cohort decoded wrong: %+v", deferred)
	}
	if failed.Cohort != "failed" || failed.Population != 18640 || failed.NeverCovered != 5 ||
		failed.TooYoung != 5 || failed.Matured != 18635 {
		t.Fatalf("failed cohort decoded wrong: %+v", failed)
	}
	// The split that turns five never-covered rows into THREE production ones.
	if len(failed.NeverCoveredByEnvironment) != 2 ||
		failed.NeverCoveredByEnvironment[0] != (cloudclient.DeployCoverageEnvironment{Environment: "production", NeverCovered: 3}) ||
		failed.NeverCoveredByEnvironment[1] != (cloudclient.DeployCoverageEnvironment{Environment: "preview", NeverCovered: 2}) {
		t.Fatalf("environment split decoded wrong: %+v", failed.NeverCoveredByEnvironment)
	}
	if failed.OldestPendingSeconds == nil || *failed.OldestPendingSeconds != 913247.0 {
		t.Fatalf("oldest_pending_seconds decoded wrong: %v", failed.OldestPendingSeconds)
	}
	// A pointer, so "no row is pending" stays absent instead of decoding into a
	// bound of zero seconds.
	if deferred.OldestPendingSeconds != nil {
		t.Fatalf("a null bound must stay nil, not 0.0: %v", deferred.OldestPendingSeconds)
	}

	// dr-w34-s1. The covering query's bound as a TOKEN, and the named tail with
	// its two companions. Every one of these names — site_id, name, slug,
	// environment, never_covered — already exists as a json tag elsewhere in
	// internal/cloudclient, so the file-global tag union is structurally blind
	// to a DeployCoverageSite declared with zero fields. DisallowUnknownFields
	// above and the assertions below are what make that shape lose.
	if c.CoveringBound != "left_only" {
		t.Fatalf("covering_bound decoded wrong: %q — the reader cannot state a bound it did not read", c.CoveringBound)
	}
	if len(c.NeverCoveredSites) != 2 {
		t.Fatalf("never_covered_sites decoded wrong: %+v", c.NeverCoveredSites)
	}
	want := cloudclient.DeployCoverageSite{
		SiteID:       "0f5f0a6e-2c1e-4a0f-9f2a-0c9f1d7a1111",
		Name:         "Jarl Website",
		Slug:         "jarl-website",
		Environment:  "production",
		NeverCovered: 3,
	}
	if c.NeverCoveredSites[0] != want {
		t.Fatalf("the named site decoded wrong: %+v (want %+v) — a struct that drops a field decodes every name to the zero value in silence", c.NeverCoveredSites[0], want)
	}
	// The list is CUT, and the cut says so: two rows out of seven.
	if c.NeverCoveredSitesTotal != 7 || !c.NeverCoveredSitesTruncated {
		t.Fatalf("the truncation companions decoded wrong: total=%d truncated=%v", c.NeverCoveredSitesTotal, c.NeverCoveredSitesTruncated)
	}
}

// TestCloudDeploymentsCoverageSiteTagsAreOnTheStructItself: the D260 blind spot,
// at its structural MAXIMUM. `site_id`, `name`, `slug`, `environment` and
// `never_covered` are ALL already json tags on other structs in
// internal/cloudclient, so the Elixir-side census's file-global UNREAD arm and
// its exact @go_tag_floor would both stay green with DeployCoverageSite carrying
// no fields at all — the control plane would emit the full named list and the
// operator's terminal would drop every name on the floor. These are the
// per-struct assertions the union cannot make.
func TestCloudDeploymentsCoverageSiteTagsAreOnTheStructItself(t *testing.T) {
	for _, tc := range []struct {
		name string
		got  any
		want any
	}{
		{"site_id", cloudclient.DeployCoverageSite{SiteID: "s"}.SiteID, "s"},
		{"name", cloudclient.DeployCoverageSite{Name: "n"}.Name, "n"},
		{"slug", cloudclient.DeployCoverageSite{Slug: "g"}.Slug, "g"},
		{"environment", cloudclient.DeployCoverageSite{Environment: "production"}.Environment, "production"},
		{"never_covered", cloudclient.DeployCoverageSite{NeverCovered: 3}.NeverCovered, 3},
	} {
		if tc.got != tc.want {
			t.Fatalf("DeployCoverageSite.%s does not carry its value", tc.name)
		}
	}

	// And the decode is per-FIELD, not per-struct: a payload naming only one key
	// must land on that key. This is what fails if a field is renamed or its tag
	// is dropped while the struct still exists.
	for _, tc := range []struct {
		json string
		want cloudclient.DeployCoverageSite
	}{
		{`{"site_id":"abc"}`, cloudclient.DeployCoverageSite{SiteID: "abc"}},
		{`{"name":"Jarl"}`, cloudclient.DeployCoverageSite{Name: "Jarl"}},
		{`{"slug":"jarl"}`, cloudclient.DeployCoverageSite{Slug: "jarl"}},
		{`{"environment":"preview"}`, cloudclient.DeployCoverageSite{Environment: "preview"}},
		{`{"never_covered":4}`, cloudclient.DeployCoverageSite{NeverCovered: 4}},
	} {
		dec := json.NewDecoder(strings.NewReader(tc.json))
		dec.DisallowUnknownFields()
		var got cloudclient.DeployCoverageSite
		if err := dec.Decode(&got); err != nil {
			t.Fatalf("%s is not decoded by DeployCoverageSite itself: %v", tc.json, err)
		}
		if got != tc.want {
			t.Fatalf("%s decoded to %+v, want %+v", tc.json, got, tc.want)
		}
	}

	// The same assertion for the two companions and the bound, on the CONTAINER
	// struct — a named list whose total decodes nowhere is a cut nobody can see.
	dec := json.NewDecoder(strings.NewReader(`{"covering_bound":"left_only","never_covered_sites_total":9,"never_covered_sites_truncated":true}`))
	dec.DisallowUnknownFields()
	var c cloudclient.DeployCoverageCohorts
	if err := dec.Decode(&c); err != nil {
		t.Fatalf("the bound and the truncation companions are UNREAD by DeployCoverageCohorts: %v", err)
	}
	if c.CoveringBound != "left_only" || c.NeverCoveredSitesTotal != 9 || !c.NeverCoveredSitesTruncated {
		t.Fatalf("decoded wrong: %+v", c)
	}
}

// TestCloudDeploymentsCoverageRendersBothCohorts: the human render, on RENDERED
// BYTES. The failed tail must be visible AS ITS OWN COHORT and the production /
// preview split must reach the screen — three production rows hidden inside a
// five-row total is the mis-report this section exists to end.
func TestCloudDeploymentsCoverageRendersBothCohorts(t *testing.T) {
	newCensusServer(t, 200, censusCoverageEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-09T11:00:00Z", "--to", "2026-08-09T12:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	deferredLine := censusLineContaining(t, stdout, "deferred   2816 of 2816 covered")
	if !strings.Contains(deferredLine, "0 NEVER COVERED") {
		t.Fatalf("the deferred cohort must print its never-covered count:\n%s", stdout)
	}
	failedLine := censusLineContaining(t, stdout, "failed     18630 of 18640 covered")
	for _, want := range []string{"5 NEVER COVERED", "5 too young to judge", "0 unreadable", "oldest still uncovered >="} {
		if !strings.Contains(failedLine, want) {
			t.Fatalf("the failed cohort must print %q beside its coverage:\n%s", want, stdout)
		}
	}
	if !strings.Contains(stdout, "never covered in production: 3") ||
		!strings.Contains(stdout, "never covered in preview: 2") {
		t.Fatalf("the environment split must reach the screen:\n%s", stdout)
	}
	// The fence is stated, so "5 never covered" can never be read without the
	// bar those five rows cleared.
	if !strings.Contains(stdout, "older than 24h") {
		t.Fatalf("the maturity fence must be printed beside the counts:\n%s", stdout)
	}
	// D478's wording fence, on the bytes an operator receives.
	for _, forbidden := range []string{"delivered", "superseded", "publish reach"} {
		if strings.Contains(strings.ToLower(stdout), forbidden) {
			t.Fatalf("the struck word %q reached the coverage render:\n%s", forbidden, stdout)
		}
	}
	// And the inference the fence alone cannot stop: on the FAILED cohort,
	// COVERED must be denied the reading "that failure turned out fine".
	if !strings.Contains(stdout, "never that the failure was repaired") {
		t.Fatalf("the failed cohort's COVERED must state what it does NOT mean:\n%s", stdout)
	}

	// dr-w34-s1. THE NON-ZERO NAMES ITS SITES, on the bytes an operator reads.
	// A never-covered count with no name sends a human looking through the whole
	// fleet for the three rows that are dark.
	for _, want := range []string{
		// PAIRS, not sites: the total counts {site_id, environment} groups, so a
		// header saying "sites" would give 7 a different meaning here than in the
		// cut marker three lines down.
		"never-covered {site, environment} pairs (2 of 7)",
		"jarl-website",
		"preview-box",
		"3 row(s) never covered",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("the named never-covered tail must reach the screen (%q):\n%s", want, stdout)
		}
	}
	// …and the cut says so, with its own unbounded total, so a top-2 can never
	// be read as the whole tail.
	if !strings.Contains(stdout, "the list is CUT: 7 {site, environment} pair(s) are never-covered and 2 are printed") {
		t.Fatalf("a truncated list must disclose its own population:\n%s", stdout)
	}
	// The covering query's bound, as a sentence, not as a paragraph to parse.
	if !strings.Contains(stdout, "covering bound: LEFT ONLY") ||
		!strings.Contains(stdout, "is the site stuck NOW") {
		t.Fatalf("the covering bound must be stated:\n%s", stdout)
	}
	// This run pinned BOTH edges with --from/--to, so it says so — the sentence
	// that separates a moving window from a fixed one.
	if !strings.Contains(stdout, "window: BOTH edges pinned by --from/--to") {
		t.Fatalf("a pinned window must be named as pinned:\n%s", stdout)
	}
	if strings.Contains(stdout, "LEFT-TRUNCATED") {
		t.Fatalf("a --from/--to window is not left-truncated:\n%s", stdout)
	}
	t.Logf("`bp cloud deployments` coverage section:\n%s", stdout)
}

// TestCloudDeploymentsCoverageDaysWindowDisclosesTruncation: the '0' in "reads 0,
// 3 or 5". The DEFAULT window is 7 days wide and its left edge slides with the
// clock, so a never-covered row written eight days ago is not in the population
// AT ALL — and the same fleet answers 0 at --days 7 and 5 at --days 27 with not
// one row changing. The number is right; the reading is what needs the sentence.
func TestCloudDeploymentsCoverageDaysWindowDisclosesTruncation(t *testing.T) {
	newCensusServer(t, 200, censusCoverageEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--days", "7")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	for _, want := range []string{
		"window: LEFT-TRUNCATED",
		"right edge at NOW",
		"only --from/--to pins both edges",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("a --days window must disclose that it truncates (%q):\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, "BOTH edges pinned") {
		t.Fatalf("a --days window is not pinned on both edges:\n%s", stdout)
	}
	t.Logf("`bp cloud deployments --days 7` coverage window disclosure:\n%s", stdout)
}

// TestCloudDeploymentsCoverageWithoutSitesSaysNotNamed: an older control plane
// sends the coverage node WITHOUT the per-site breakdown. That is not an empty
// backlog and it is not a named one — the counts are real and WHICH sites they
// belong to was never read. Three states, kept apart.
func TestCloudDeploymentsCoverageWithoutSitesSaysNotNamed(t *testing.T) {
	newCensusServer(t, 200, censusCoverageEnvelopeWithoutSites)
	pinCensusClock(t, time.Date(2026, 8, 9, 12, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-09T11:00:00Z", "--to", "2026-08-09T12:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "sites: NOT NAMED") ||
		!strings.Contains(stdout, "that is not the same as none") {
		t.Fatalf("an absent per-site breakdown must refuse out loud:\n%s", stdout)
	}
	// An unstated bound is not "left only" either.
	if !strings.Contains(stdout, "covering bound: NOT STATED") {
		t.Fatalf("an absent covering_bound must say so rather than assume:\n%s", stdout)
	}
	// And nothing may be invented: no name, no cut, no zero.
	// The forbidden prefix must track the header VERBATIM — a stale literal here
	// would pass vacuously against a renamed header, which is the one way this
	// negative assertion can stop being a guard.
	for _, forbidden := range []string{"never-covered {site, environment} pairs (", "the list is CUT", "sites: none"} {
		if strings.Contains(stdout, forbidden) {
			t.Fatalf("nothing may be claimed about WHICH sites when none were sent (%q):\n%s", forbidden, stdout)
		}
	}
}

// TestCloudDeploymentsWithoutCoverageSaysNotMeasured: an absent key is not an
// empty backlog. A control plane that does not send `coverage_cohorts` has not
// measured coverage, and the section must say so rather than print nothing —
// printing nothing is what let an unmeasured gauge read as a clean one.
func TestCloudDeploymentsWithoutCoverageSaysNotMeasured(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "NOT MEASURED — this control plane sends no coverage census")
	if !strings.Contains(line, "UNCOUNTED here, and that is NOT the same as none") {
		t.Fatalf("a missing coverage census must refuse out loud:\n%s", stdout)
	}
	for _, forbidden := range []string{"NEVER COVERED", "never covered in "} {
		if strings.Contains(stdout, forbidden) {
			t.Fatalf("nothing may be claimed about coverage when none was sent (%q):\n%s", forbidden, stdout)
		}
	}
}

// ─── A REFUSED SHARE NAMES THE WINDOW THAT WOULD ANSWER (dr-w30-s5) ──────────
//
// Measured against the live control plane on 2026-08-09: over the 7-day default
// window all 14 failure-class shares refuse (the window STRADDLES the
// deferred-settle boundary), while `--from 2026-08-05T21:13:50Z` answers every
// one of them. The render had no way to say so, and an em-dash cell is a dead
// end.
//
// The fixtures below are the THREE envelope shapes that decide what may be
// said: a straddle refusal (the reason itself names the instant), a sample
// refusal beside a boundary list (no --from can help, and the render must not
// pretend otherwise), and an envelope with NO boundaries at all (nothing may be
// invented). EVERY instant asserted below is supplied by the fixture — a
// hardcoded boundary in the renderer fails the third test by appearing where
// the envelope never sent it.

// censusStraddleEnvelope: shares refused because the window straddles the
// vocabulary boundary — the control plane's reason NAMES the instant, and the
// `boundaries` list carries its derivation.
const censusStraddleEnvelope = `{
  "window": {"from": "2026-08-02T00:00:00Z", "to": "2026-08-09T00:00:00Z"},
  "volume": 8678,
  "failed": 3444,
  "failure_rate": {"sample": 8678, "pct": null, "numerator": 3444, "min_sample": 200, "refused": true,
    "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"},
  "classes": [
    {"class": "DOC_ID_EMPTY", "label": "the cause went unrecorded", "count": 1149,
     "share": {"sample": 3444, "pct": null, "numerator": 1149, "min_sample": 200, "refused": true,
       "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"}},
    {"class": "BOX_500", "label": "the box errored on the deploy (HTTP 500)", "count": 399,
     "share": {"sample": 3444, "pct": null, "numerator": 399, "min_sample": 200, "refused": true,
       "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"}}
  ],
  "deferred": [
    {"class": "BOX_AT_CAPACITY_DEFERRED", "label": "the box was at its cap; re-queued", "count": 2539,
     "share": {"sample": 8678, "pct": 29.26, "numerator": 2539, "min_sample": 200, "refused": false, "reason": null}}
  ],
  "not_attempted": [],
  "sites": [],
  "boundaries": [
    {"subject": "deferred settle status", "instant": "2026-08-05T21:13:50Z", "method": "schema_commit", "source": "#9615",
     "voids": "before this instant no row could settle deferred"},
    {"subject": "deferred settle status", "instant": "2026-08-05T21:27:11.413210Z", "method": "first_observed_row",
     "source": "min(inserted_at) where status = deferred", "voids": "corroborating twin"}
  ],
  "min_sample": 200
}`

// censusMixedSampleEnvelope: two class shares refuse with the SAME reason and
// were denominated over DIFFERENT samples. The control plane's straddle reason
// carries no denominator, so a render that groups by reason alone would print
// one row's n beside a count covering both — a denominator no row was taken
// over. The two rows must be reported separately.
const censusMixedSampleEnvelope = `{
  "window": {"from": "2026-08-02T00:00:00Z", "to": "2026-08-09T00:00:00Z"},
  "volume": 8678,
  "failed": 3444,
  "failure_rate": {"sample": 8678, "pct": null, "numerator": 3444, "min_sample": 200, "refused": true,
    "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"},
  "classes": [
    {"class": "DOC_ID_EMPTY", "label": "the cause went unrecorded", "count": 1149,
     "share": {"sample": 3444, "pct": null, "numerator": 1149, "min_sample": 200, "refused": true,
       "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"}},
    {"class": "BOX_500", "label": "the box errored on the deploy (HTTP 500)", "count": 399,
     "share": {"sample": 1201, "pct": null, "numerator": 399, "min_sample": 200, "refused": true,
       "reason": "the window STRADDLES the deferred settle status boundary at 2026-08-05T21:13:50Z (method: schema_commit, source: #9615) — a blend of two taxonomies, not a measurement"}}
  ],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "boundaries": [
    {"subject": "deferred settle status", "instant": "2026-08-05T21:13:50Z", "method": "schema_commit", "source": "#9615",
     "voids": "before this instant no row could settle deferred"}
  ],
  "min_sample": 200
}`

// censusSampleRefusalEnvelope: the shares refuse for SAMPLE, on a window that
// already sits wholly AFTER the boundary. Narrowing can only shrink the sample,
// so there is no `--from` to suggest and the render must say that outright.
const censusSampleRefusalEnvelope = `{
  "window": {"from": "2026-08-08T00:00:00Z", "to": "2026-08-09T00:00:00Z"},
  "volume": 74,
  "failed": 31,
  "failure_rate": {"sample": 74, "pct": null, "numerator": 31, "min_sample": 200, "refused": true,
    "reason": "sample 74 below min_sample 200"},
  "classes": [
    {"class": "BOX_500", "label": "the box errored on the deploy (HTTP 500)", "count": 20,
     "share": {"sample": 31, "pct": null, "numerator": 20, "min_sample": 200, "refused": true,
       "reason": "sample 31 below min_sample 200"}}
  ],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "boundaries": [
    {"subject": "deferred settle status", "instant": "2026-08-05T21:13:50Z", "method": "schema_commit", "source": "#9615",
     "voids": "before this instant no row could settle deferred"}
  ],
  "min_sample": 200
}`

// censusNoBoundaryEnvelope: a refused share on a control plane that names NO
// boundary at all. Every fact a suggestion needs is missing, so the only honest
// render is the refusal to guess one.
const censusNoBoundaryEnvelope = `{
  "window": {"from": "2026-08-08T00:00:00Z", "to": "2026-08-09T00:00:00Z"},
  "volume": 74,
  "failed": 31,
  "failure_rate": {"sample": 74, "pct": null, "numerator": 31, "min_sample": 200, "refused": true,
    "reason": "sample 74 below min_sample 200"},
  "classes": [
    {"class": "BOX_500", "label": "the box errored on the deploy (HTTP 500)", "count": 20,
     "share": {"sample": 31, "pct": null, "numerator": 20, "min_sample": 200, "refused": true,
       "reason": "sample 31 below min_sample 200"}}
  ],
  "deferred": [],
  "not_attempted": [],
  "sites": [],
  "min_sample": 200
}`

// TestCloudDeploymentsRefusedShareNamesTheWindow: a straddle-refused share
// prints the control plane's reason WITH its denominator, and the `--from` that
// would keep the window inside one vocabulary — read out of the refusal the
// fixture supplied, never hardcoded.
func TestCloudDeploymentsRefusedShareNamesTheWindow(t *testing.T) {
	newCensusServer(t, 200, censusStraddleEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	note := censusLineContaining(t, stdout, "NO SHARE for")
	// The population rides the refusal line: 2 of 2 class rows, denominated on
	// the 3444 settled failures — never a bare "refused".
	for _, want := range []string{"2 of 2 rows", "n=3444", "STRADDLES"} {
		if !strings.Contains(note, want) {
			t.Fatalf("refusal note %q missing %q", note, want)
		}
	}

	// The headline carries its own copy of this remedy now (dr-w30-followup),
	// so the SHARE remedy is looked up inside the classes region.
	classes := stdout[strings.Index(stdout, "failure classes"):]
	remedy := censusLineContaining(t, classes, "A WINDOW THAT COULD ANSWER")
	for _, want := range []string{
		"--from 2026-08-05T21:13:50Z",
		"--to 2026-08-09T00:00:00Z",
		"schema_commit",
		"#9615",
		"min_sample 200",
	} {
		if !strings.Contains(remedy, want) {
			t.Fatalf("suggested window %q missing %q — the boundary, its provenance and the caveat all come off the envelope", remedy, want)
		}
	}

	// THE DEFERRAL SHARES ARE A SEPARATE RENDER WITH A SEPARATE DENOMINATOR, and
	// they did NOT refuse here — so no note may attach to them. A merged note
	// would put a 3444-denominated refusal under rows denominated on 8678.
	deferrals := stdout[strings.Index(stdout, "deferrals (in the volume"):]
	if strings.Contains(deferrals, "NO SHARE for") {
		t.Fatalf("a section whose shares all answered must carry no refusal note:\n%s", deferrals)
	}
	if !strings.Contains(deferrals, "29.26%") {
		t.Fatalf("the deferral share must still render its own percentage:\n%s", deferrals)
	}
}

// TestCloudDeploymentsSampleRefusalOffersNoImpossibleWindow: a share refused for
// SAMPLE gets the boundary and the truth — no narrower `--from` can raise a
// sample — rather than a trim that would make the refusal worse.
func TestCloudDeploymentsSampleRefusalOffersNoImpossibleWindow(t *testing.T) {
	newCensusServer(t, 200, censusSampleRefusalEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-08T00:00:00Z", "--to", "2026-08-09T00:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	note := censusLineContaining(t, stdout, "NO SHARE for")
	if !strings.Contains(note, "sample 31 below min_sample 200") || !strings.Contains(note, "n=31") {
		t.Fatalf("the sample refusal must be quoted with its denominator: %q", note)
	}
	// The headline refusal carries the same no-window truth now (dr-w30-followup),
	// so the SHARE remedy is looked up inside the classes region.
	classes := stdout[strings.Index(stdout, "failure classes"):]
	remedy := censusLineContaining(t, classes, "NO --from CAN UN-REFUSE THIS")
	for _, want := range []string{"2026-08-05T21:13:50Z", "wholly after", "schema_commit"} {
		if !strings.Contains(remedy, want) {
			t.Fatalf("sample-refusal remedy %q missing %q", remedy, want)
		}
	}
	if strings.Contains(stdout, "A WINDOW THAT COULD ANSWER") {
		t.Fatalf("a sample refusal must NOT be offered a narrower window — that makes it worse:\n%s", stdout)
	}
}

// TestCloudDeploymentsRefusedShareInventsNoWindow: with no `boundaries` in the
// envelope there is nothing to build a suggestion on, and the render says so
// instead of guessing an instant.
func TestCloudDeploymentsRefusedShareInventsNoWindow(t *testing.T) {
	newCensusServer(t, 200, censusNoBoundaryEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-08T00:00:00Z", "--to", "2026-08-09T00:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	if !strings.Contains(stdout, "NO WINDOW SUGGESTION") || !strings.Contains(stdout, "Nothing was invented") {
		t.Fatalf("an envelope with no boundary must say so, not guess:\n%s", stdout)
	}
	// The one thing that must NEVER appear: an instant this control plane did
	// not send. A hardcoded boundary would surface exactly here.
	if strings.Contains(stdout, "2026-08-05T21:13:50Z") {
		t.Fatalf("an instant the envelope never carried was rendered — the boundary is hardcoded somewhere:\n%s", stdout)
	}
}

// TestCloudDeploymentsHeadlineRefusalNamesTheWindow
// (dr-w30-followup-headline-refusal-names-the-window): the HEADLINE
// failure_rate refusal carries the same envelope-read window remedy the share
// refusals carry — rendered in the headline region, above the classes, off the
// same deployCensusShareRemedy. Before this, the operator read 'failure NO RATE
// — the window STRADDLES … boundary at <instant>' and was never told that
// `--from <instant>` answers it — dr-w30-s5 cured the shares and deliberately
// left the headline outside its cut.
func TestCloudDeploymentsHeadlineRefusalNamesTheWindow(t *testing.T) {
	newCensusServer(t, 200, censusStraddleEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	head := stdout[:strings.Index(stdout, "failure classes")]
	remedy := censusLineContaining(t, head, "A WINDOW THAT COULD ANSWER")
	for _, want := range []string{
		"--from 2026-08-05T21:13:50Z",
		"--to 2026-08-09T00:00:00Z",
		"schema_commit",
		"#9615",
		"min_sample 200",
	} {
		if !strings.Contains(remedy, want) {
			t.Fatalf("headline remedy %q missing %q — the boundary, its provenance and the caveat all come off the envelope", remedy, want)
		}
	}
}

// TestCloudDeploymentsHeadlineSampleRefusalOffersNoImpossibleWindow: a headline
// refused for SAMPLE gets the same honest no-window truth the shares get — a
// narrower --from can only shrink the sample, and the render says so in the
// headline region instead of offering a trim that would make it worse.
func TestCloudDeploymentsHeadlineSampleRefusalOffersNoImpossibleWindow(t *testing.T) {
	newCensusServer(t, 200, censusSampleRefusalEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table", "--from", "2026-08-08T00:00:00Z", "--to", "2026-08-09T00:00:00Z")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	head := stdout[:strings.Index(stdout, "failure classes")]
	remedy := censusLineContaining(t, head, "NO --from CAN UN-REFUSE THIS")
	for _, want := range []string{"2026-08-05T21:13:50Z", "wholly after"} {
		if !strings.Contains(remedy, want) {
			t.Fatalf("headline sample-refusal remedy %q missing %q", remedy, want)
		}
	}
	if strings.Contains(head, "A WINDOW THAT COULD ANSWER") {
		t.Fatalf("a headline sample refusal must NOT be offered a narrower window:\n%s", head)
	}
}

// TestCloudDeploymentsAnsweredHeadlineCarriesNoRemedy keeps the headline remedy
// FALSIFIABLE: a headline that produced a percentage gets no remedy line at all
// — a remedy under an answered rate would read as doubt the answer never
// expressed.
func TestCloudDeploymentsAnsweredHeadlineCarriesNoRemedy(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, _, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	head := stdout[:strings.Index(stdout, "failure classes")]
	for _, unwanted := range []string{"A WINDOW THAT COULD ANSWER", "NO --from CAN UN-REFUSE", "NO WINDOW SUGGESTION"} {
		if strings.Contains(head, unwanted) {
			t.Fatalf("an answered headline acquired a remedy (%q):\n%s", unwanted, head)
		}
	}
}

// TestCloudDeploymentsAnsweredSharesCarryNoNote: shares that produced a
// percentage get no refusal note at all — this block is a note about refusals,
// not a caption on every table.
// Two rows, one reason, two denominators. The refusal note groups by
// (reason, SAMPLE) precisely so the printed n is a denominator the counted rows
// were actually taken over; grouping by reason alone prints "2 of 2 rows …
// n=3444" and silently attributes BOX_500's 1201 to the larger population.
func TestCloudDeploymentsRefusalNoteSplitsOnTheDenominator(t *testing.T) {
	newCensusServer(t, 200, censusMixedSampleEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}

	var notes []string
	for _, line := range strings.Split(stdout, "\n") {
		if strings.Contains(line, "NO SHARE for") {
			notes = append(notes, line)
		}
	}
	if len(notes) != 2 {
		t.Fatalf("two rows refused over two different denominators, want two refusal notes, got %d:\n%s", len(notes), stdout)
	}
	for _, want := range []string{"1 of 2 rows above (share denominator n=3444)", "1 of 2 rows above (share denominator n=1201)"} {
		found := false
		for _, note := range notes {
			if strings.Contains(note, want) {
				found = true
			}
		}
		if !found {
			t.Fatalf("no refusal note carries %q — a note may never quote a denominator its counted rows were not taken over:\n%s", want, strings.Join(notes, "\n"))
		}
	}
}

func TestCloudDeploymentsAnsweredSharesCarryNoNote(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, _, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, unwanted := range []string{"NO SHARE for", "A WINDOW THAT COULD ANSWER", "NO WINDOW SUGGESTION"} {
		if strings.Contains(stdout, unwanted) {
			t.Fatalf("a census whose shares all answered printed %q:\n%s", unwanted, stdout)
		}
	}
}

// TestCloudDeploymentsForbiddenGetsNoWindowSuggestion: the CREDENTIAL refusal
// keeps its own wording and acquires NO window suggestion — no window fixes a
// token that lacks ability "read", and offering one would send the operator to
// re-run a command that cannot succeed.
func TestCloudDeploymentsForbiddenGetsNoWindowSuggestion(t *testing.T) {
	newCensusServer(t, 403, `{"error":"forbidden","scope":"team","required":"read"}`)
	pinCensusClock(t, time.Date(2026, 8, 9, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	all := stdout + stderr
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d\n%s", code, exitAuth, all)
	}
	if !strings.Contains(all, "403 forbidden") || !strings.Contains(all, `ability "read"`) {
		t.Fatalf("the credential refusal lost its own wording:\n%s", all)
	}
	for _, unwanted := range []string{"A WINDOW THAT COULD ANSWER", "NO --from CAN UN-REFUSE", "NO WINDOW SUGGESTION"} {
		if strings.Contains(all, unwanted) {
			t.Fatalf("a 403 acquired a window suggestion (%q) — no window fixes a credential:\n%s", unwanted, all)
		}
	}
}

// ─── THE SITE ROWS: WHAT SHIPPED, AND WHY THERE IS NO RATE ───────────────────

// censusSiteRealEnvelope carries the site row MEASURED on a real 200 against a
// team credential and quoted on cloudclient.DeployCensusSite —
// {"volume":435,"failed":1,"deferred":325,"live":109}, which sums exactly — next
// to a second, LOW-VOLUME site whose own rate the producer refuses.
//
// Both halves come off the real producer, not off an assumed shape: site_row/2
// denominates each site's `failure_rate` on that SITE's own volume via
// rate_basis/3, and rate/2 refuses below @min_sample 200 with the reason
// verbatim below. Every site fixture that existed before this one had a volume
// of 1016 or more, so the refusing branch had never once been rendered.
const censusSiteRealEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 470,
  "failed": 4,
  "live": 118,
  "failure_rate": {"sample": 470, "pct": 0.85, "numerator": 4, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "deferred": [],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-real", "volume": 435, "failed": 1, "deferred": 325, "live": 109,
     "failure_rate": {"sample": 435, "pct": 0.23, "numerator": 1, "min_sample": 200, "refused": false, "reason": null},
     "top_class": "BOX_BUSY_409"},
    {"site_id": "site-quiet", "volume": 35, "failed": 3, "deferred": 23, "live": 9,
     "failure_rate": {"sample": 35, "pct": null, "numerator": 3, "min_sample": 200, "refused": true,
                      "reason": "sample 35 below min_sample 200"},
     "top_class": "DOC_ID_EMPTY"}
  ],
  "min_sample": 200
}`

// TestCloudDeploymentsSiteRowNamesWhatShipped: the site row says how many of its
// attempts went LIVE. On the real row above, 109 of 435 shipped while the render
// showed "1 failed" and a 0.2% rate — a site a reader would call healthy. The
// reader cannot recover 109 by subtraction (that is site_row/2's forbidden
// arithmetic), so the wire's own `live` has to reach the screen.
func TestCloudDeploymentsSiteRowNamesWhatShipped(t *testing.T) {
	newCensusServer(t, 200, censusSiteRealEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	row := censusLineContaining(t, stdout, "site-real")
	for _, want := range []string{"435 attempted", "109 live", "1 failed", "325 deferred"} {
		if !strings.Contains(row, want) {
			t.Fatalf("site row %q missing %q — the row must name what SHIPPED beside what failed", row, want)
		}
	}
	// A payload that names per-site live owes no UNMETERED note.
	if strings.Contains(stdout, "PER-SITE LIVE UNMETERED") {
		t.Fatalf("every row carried `live`, so no unmetered note may print:\n%s", stdout)
	}
}

// TestCloudDeploymentsSiteLiveCellTracksTheWire is the MUTATION PROOF for the
// live cell: the same render over a payload whose only difference is the site's
// `live` must print a different number. A cell that renders identically under a
// changed fact is decoration, not a reading.
func TestCloudDeploymentsSiteLiveCellTracksTheWire(t *testing.T) {
	render := func(t *testing.T, body string) string {
		t.Helper()
		newCensusServer(t, 200, body)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))
		stdout, stderr, code := runDeployments(t, "table")
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		return censusLineContaining(t, stdout, "site-real")
	}

	truth := render(t, censusSiteRealEnvelope)
	mutated := render(t, strings.Replace(censusSiteRealEnvelope,
		`"deferred": 325, "live": 109`, `"deferred": 325, "live": 7`, 1))

	if truth == mutated {
		t.Fatalf("the site row did not move when `live` moved 109 → 7 — the cell is not reading the wire:\n%s", truth)
	}
	if !strings.Contains(truth, "109 live") || !strings.Contains(mutated, "7 live") {
		t.Fatalf("live cell did not track the payload:\ntruth:   %s\nmutated: %s", truth, mutated)
	}
	// AND THE ABSENCE IS ITS OWN THIRD STATE, never a zero: a control plane
	// predating #10519 sends no per-site `live` key at all.
	absent := render(t, strings.Replace(censusSiteRealEnvelope, `"deferred": 325, "live": 109`, `"deferred": 325`, 1))
	if !strings.Contains(absent, "UNMETERED") {
		t.Fatalf("a missing per-site `live` must render UNMETERED, never a count: %s", absent)
	}
	if strings.Contains(absent, "0 live") {
		t.Fatalf("a missing per-site `live` rendered as zero-live — the most alarming reading of an absence: %s", absent)
	}
}

// TestCloudDeploymentsSiteRefusalIsNamed: the em-dash in a site's share cell is
// a REFUSAL, and the section says so with the denominator it was refused on and
// the remedy that actually applies. Before this, the class and deferral sections
// each carried deployCensusShareNotes and the site section carried nothing.
func TestCloudDeploymentsSiteRefusalIsNamed(t *testing.T) {
	newCensusServer(t, 200, censusSiteRealEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	note := censusLineContaining(t, stdout, "NO PER-SITE RATE")
	// ONE of the two rows refused, on ITS OWN volume of 35, against the floor of
	// 200 — never the fleet's 470.
	for _, want := range []string{"1 of 2 rows", "n=35", "min_sample 200", "REFUSAL"} {
		if !strings.Contains(note, want) {
			t.Fatalf("site refusal note %q missing %q", note, want)
		}
	}
	remedy := censusLineContaining(t, stdout, "NO --from CAN UN-REFUSE THESE")
	if !strings.Contains(remedy, "SHRINK") {
		t.Fatalf("a per-site sample refusal must say the sample has to GROW: %q", remedy)
	}
	// A sample floor is not a vocabulary straddle: offering a narrower window
	// would send the operator to a smaller sample.
	if strings.Contains(stdout, "A WINDOW THAT COULD ANSWER") {
		t.Fatalf("a per-site sample refusal was offered a narrower window:\n%s", stdout)
	}
}

// TestCloudDeploymentsSiteNoteCanBeAbsent is the guard that keeps the note
// FALSIFIABLE. A note that renders on every payload proves nothing about the one
// on screen — so a section where every site rate answered must carry no note at
// all. censusTodayEnvelope's two sites are 1200 and 1016, both above the floor.
func TestCloudDeploymentsSiteNoteCanBeAbsent(t *testing.T) {
	newCensusServer(t, 200, censusTodayEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	sites := stdout[strings.Index(stdout, "sites (by volume)"):]
	if strings.Contains(sites, "NO PER-SITE RATE") {
		t.Fatalf("both site rates answered, so no refusal note may print:\n%s", sites)
	}
	if !strings.Contains(sites, "41.67%") || !strings.Contains(sites, "32.68%") {
		t.Fatalf("the answered per-site rates must still render their percentages:\n%s", sites)
	}
	// TODAY'S payload carries no per-site `live` — which is a fact the reader
	// owes its operator, together with the subtraction it must not perform.
	note := censusLineContaining(t, stdout, "PER-SITE LIVE UNMETERED")
	for _, want := range []string{"2 of 2 rows", "NOT the answer"} {
		if !strings.Contains(note, want) {
			t.Fatalf("unmetered note %q missing %q", note, want)
		}
	}
}

// TestCloudDeploymentsSiteNotesDescribeTheRenderedRows: --sites clamps the rows
// on screen, and the notes must count the rows a human can actually see. A note
// denominated on the full list would accuse rows the clamp hid.
//
// BOTH HALVES ARE ASSERTED, and the positive one is why this test is not
// vacuous. Checked against the pre-fix renderer, an absence-only assertion
// passes for the wrong reason — no note printed under ANY clamp — which is the
// exact shape of a test that cannot fail on the change it exists to guard.
func TestCloudDeploymentsSiteNotesDescribeTheRenderedRows(t *testing.T) {
	render := func(t *testing.T, args ...string) string {
		t.Helper()
		newCensusServer(t, 200, censusSiteRealEnvelope)
		pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))
		stdout, stderr, code := runDeployments(t, "table", args...)
		if code != exitOK {
			t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
		}
		return stdout
	}

	// UNCLAMPED: the refusing row is on screen, so its refusal is named and
	// counted against the two rows that are.
	both := render(t, "--sites", "2")
	if !strings.Contains(both, "site-quiet") {
		t.Fatalf("--sites 2 must render both rows:\n%s", both)
	}
	note := censusLineContaining(t, both, "NO PER-SITE RATE")
	if !strings.Contains(note, "1 of 2 rows") {
		t.Fatalf("the note must count the rows on screen: %q", note)
	}

	// CLAMPED: the refusing row is gone, so the note that accused it must go
	// with it — while the clamp still discloses what it hid.
	one := render(t, "--sites", "1")
	if strings.Contains(one, "site-quiet") {
		t.Fatalf("--sites 1 must clamp the second row away:\n%s", one)
	}
	if strings.Contains(one, "NO PER-SITE RATE") {
		t.Fatalf("a refusal note survived the clamp that hid the refusing row:\n%s", one)
	}
	if !strings.Contains(one, "… and 1 more") {
		t.Fatalf("the clamp must still disclose what it hid:\n%s", one)
	}
}

// ── dr-w24: the SERVER-side cut marker reaches a reader ──────────────────────
//
// `DeployLedger.census/3` clamps `sites` at 50 rows and marks the cut with
// `truncated` + `total_sites`. Before this slice no Go field declared either
// key, and the CLI's own "… and N more" line — derived from its DISPLAY clamp —
// actively reassured the reader that the list was complete. The three tests
// below pin the three honest endings: the server SAID it cut, the server SAID
// it did not, and the server (an older control plane) said NOTHING — which must
// never render as completeness.

// censusTruncatedEnvelope: two site rows survive the wire out of a 120-site
// population, and the server says so.
const censusTruncatedEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "failure_rate": {"sample": 2216, "pct": 37.5, "numerator": 832, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-alpha", "volume": 1381, "failed": 723, "deferred": 100, "failure_rate": {"sample": 1381, "pct": 52.4, "numerator": 723, "min_sample": 200, "refused": false, "reason": null}, "top_class": "BOX_BUSY_409"},
    {"site_id": "site-beta", "volume": 835, "failed": 109, "deferred": 50, "failure_rate": {"sample": 835, "pct": 13.1, "numerator": 109, "min_sample": 200, "refused": false, "reason": null}, "top_class": null}
  ],
  "total_sites": 120,
  "truncated": true,
  "min_sample": 200
}`

// censusCompleteEnvelope is the same census with the server AFFIRMING that no
// site row was cut.
const censusCompleteEnvelope = `{
  "window": {"from": "2026-07-31T00:00:00Z", "to": "2026-08-07T00:00:00Z"},
  "volume": 2216,
  "failed": 832,
  "failure_rate": {"sample": 2216, "pct": 37.5, "numerator": 832, "min_sample": 200, "refused": false, "reason": null},
  "classes": [],
  "not_attempted": [],
  "sites": [
    {"site_id": "site-alpha", "volume": 1381, "failed": 723, "deferred": 100, "failure_rate": {"sample": 1381, "pct": 52.4, "numerator": 723, "min_sample": 200, "refused": false, "reason": null}, "top_class": "BOX_BUSY_409"},
    {"site_id": "site-beta", "volume": 835, "failed": 109, "deferred": 50, "failure_rate": {"sample": 835, "pct": 13.1, "numerator": 109, "min_sample": 200, "refused": false, "reason": null}, "top_class": null}
  ],
  "total_sites": 2,
  "truncated": false,
  "min_sample": 200
}`

// TestCloudDeploymentsServerTruncationIsNamed: `truncated: true` renders the
// server's cut with BOTH numbers — rows on the wire and the real population —
// and never the display-clamp reassurance or the not-stated arm.
func TestCloudDeploymentsServerTruncationIsNamed(t *testing.T) {
	newCensusServer(t, 200, censusTruncatedEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "SERVER-TRUNCATED")
	for _, want := range []string{"2 of 120 site(s)", "TOP of the population", "no --sites value can restore"} {
		if !strings.Contains(line, want) {
			t.Fatalf("truncation line %q missing %q — the cut must carry the rows shown AND the population they were cut from", line, want)
		}
	}
	if strings.Contains(stdout, "population NOT STATED") {
		t.Fatalf("the server DID state the population; the not-stated arm must not render:\n%s", stdout)
	}
}

// TestCloudDeploymentsServerAffirmsCompleteness: `truncated: false` is a claim
// someone actually made, and it renders as one — with the population.
func TestCloudDeploymentsServerAffirmsCompleteness(t *testing.T) {
	newCensusServer(t, 200, censusCompleteEnvelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "complete: the control plane sent all")
	if !strings.Contains(line, "all 2 site(s)") {
		t.Fatalf("completeness line %q missing the affirmed population", line)
	}
	if strings.Contains(stdout, "SERVER-TRUNCATED") || strings.Contains(stdout, "population NOT STATED") {
		t.Fatalf("an affirmed-complete list must render neither the cut arm nor the not-stated arm:\n%s", stdout)
	}
}

// TestCloudDeploymentsTruncationAbsentIsNotCompleteness: an envelope with NO
// `truncated` key (every control plane older than dr-w18-s2) must say the
// population is NOT STATED — absence decoding into "complete" is the exact
// false reassurance the pointer polarity exists to prevent, and this epic's
// signature defect (ABSENT collapsed into ZERO).
func TestCloudDeploymentsTruncationAbsentIsNotCompleteness(t *testing.T) {
	newCensusServer(t, 200, censusW12S8Envelope)
	pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))

	stdout, stderr, code := runDeployments(t, "table")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstderr:\n%s", code, stderr)
	}
	line := censusLineContaining(t, stdout, "population NOT STATED")
	if !strings.Contains(line, "whole population or the top of a larger one is unknown") {
		t.Fatalf("not-stated line %q must say the completeness question is UNANSWERED, not answered", line)
	}
	if strings.Contains(stdout, "SERVER-TRUNCATED") || strings.Contains(stdout, "complete: the control plane") {
		t.Fatalf("an unstated population must claim neither cut nor complete:\n%s", stdout)
	}
}

// TestDeployCensusFourKeysDecodeAndAbsenceIsNil pins the DECODE of the four
// dr-w24 keys — and, just as load-bearing, that their ABSENCE decodes to nil,
// never to a zero-valued claim.
func TestDeployCensusFourKeysDecodeAndAbsenceIsNil(t *testing.T) {
	full := `{
	  "total_sites": 120,
	  "truncated": true,
	  "completeness": {
	    "audited": 2216, "accounted": 2200, "unaccounted": 16, "balanced": false,
	    "method": "Repo.aggregate", "reason": "16 row(s) are in the population and in NO cohort"
	  },
	  "boundaries": [
	    {"subject": "deferred settle status", "instant": "2026-08-05T21:13:50Z", "method": "schema_commit", "source": "#9615"}
	  ]
	}`
	var census cloudclient.DeployCensus
	if err := json.Unmarshal([]byte(full), &census); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if census.TotalSites == nil || *census.TotalSites != 120 {
		t.Fatalf("total_sites did not decode: %+v", census.TotalSites)
	}
	if census.Truncated == nil || !*census.Truncated {
		t.Fatalf("truncated did not decode: %+v", census.Truncated)
	}
	c := census.Completeness
	if c == nil || c.Audited != 2216 || c.Accounted != 2200 || c.Unaccounted != 16 || c.Balanced {
		t.Fatalf("completeness did not decode: %+v", c)
	}
	if c.Reason == nil || !strings.Contains(*c.Reason, "NO cohort") {
		t.Fatalf("completeness.reason did not decode: %+v", c.Reason)
	}
	if len(census.Boundaries) != 1 || census.Boundaries[0].Source != "#9615" || census.Boundaries[0].Method != "schema_commit" {
		t.Fatalf("boundaries did not decode: %+v", census.Boundaries)
	}

	var absent cloudclient.DeployCensus
	if err := json.Unmarshal([]byte(`{"volume": 10}`), &absent); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if absent.TotalSites != nil || absent.Truncated != nil || absent.Completeness != nil || absent.Boundaries != nil {
		t.Fatalf("an envelope without the four keys must decode them all to nil — absence is NOT a measurement: %+v %+v %+v %+v",
			absent.TotalSites, absent.Truncated, absent.Completeness, absent.Boundaries)
	}
	// balanced-null polarity: a BALANCED audit sends reason null, and that must
	// stay nil rather than becoming "" — "nothing to say" is not "a reason the
	// decode dropped".
	var balanced cloudclient.DeployCensus
	if err := json.Unmarshal([]byte(`{"completeness": {"audited": 5, "accounted": 5, "unaccounted": 0, "balanced": true, "method": "m", "reason": null}}`), &balanced); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if balanced.Completeness == nil || !balanced.Completeness.Balanced || balanced.Completeness.Reason != nil {
		t.Fatalf("a balanced audit must decode with reason == nil: %+v", balanced.Completeness)
	}
}

// TestDeployCensusRenderNeverSaysFleet (dr-w18-bl): the reader is TEAM-scoped
// (GET /v1/deploy-ledger/census) on every path, so no rendered sentence may
// call the population "the fleet" — on a 200 the scope line names the real
// population, and the in-band NOT MEASURED / NOT SENT sentences must not
// over-claim by one level either. The word is banned from the render outright:
// a page that covers one team's thirteen sites and says "fleet" tells a team
// owner something about every other team's deploys that this read never saw.
func TestDeployCensusRenderNeverSaysFleet(t *testing.T) {
	fixtures := map[string]string{
		"w12s8":     censusW12S8Envelope,
		"live":      censusLiveEnvelope,
		"today":     censusTodayEnvelope,
		"delivery":  censusDeliveryEnvelope,
		"truncated": censusTruncatedEnvelope,
		"thin":      censusThinEnvelope,
	}
	for name, env := range fixtures {
		t.Run(name, func(t *testing.T) {
			newCensusServer(t, 200, env)
			pinCensusClock(t, time.Date(2026, 8, 7, 0, 0, 0, 0, time.UTC))
			stdout, stderr, code := runDeployments(t, "table")
			if code != exitOK {
				t.Fatalf("exit = %d\nstderr:\n%s", code, stderr)
			}
			for _, line := range strings.Split(stdout, "\n") {
				if strings.Contains(strings.ToLower(line), "fleet") {
					t.Errorf("a team-scoped render may not say \"fleet\": %q", line)
				}
			}
		})
	}
}

// TestDeployCensusPctRendersEnvelopeVerbatim pairs fixture pcts with their
// rendered cells (dr-w8-s4 followup): the number printed IS the control
// plane's own `pct`, shortest-form, never a one-decimal re-derivation from
// numerator/sample. The 37.55 row is the one the divergence was filed on: the
// old pctOf path rendered it 37.5%, and a reader comparing the CLI against a
// raw curl of the census route had two numbers and no ruling.
func TestDeployCensusPctRendersEnvelopeVerbatim(t *testing.T) {
	cases := []struct {
		pct  float64
		want string
	}{
		{37.55, "37.55%"}, // two decimals survive
		{37.5, "37.5%"},   // one decimal stays one decimal
		{25.0, "25%"},     // a whole number is a whole number
		{74.51, "74.51%"},
	}
	for _, tc := range cases {
		r := cloudclient.DeployRate{Sample: 999, Pct: &tc.pct, Numerator: 1, MinSample: 200}
		got, okRate := deployCensusPct(r)
		if !okRate || got != tc.want {
			t.Errorf("deployCensusPct(pct=%v) = %q ok=%v, want %q — the envelope's own number, verbatim", tc.pct, got, okRate, tc.want)
		}
	}
	// Numerator/sample deliberately DISAGREE with pct above (1/999): a render
	// that recomputes instead of repeating would print 0.1% and red every row.
	refused := cloudclient.DeployRate{Sample: 12, Numerator: 3, MinSample: 200, Refused: true}
	if _, okRate := deployCensusPct(refused); okRate {
		t.Error("a refused node must never yield a percentage")
	}
	none := cloudclient.DeployRate{Sample: 500, Numerator: 3, MinSample: 200}
	if _, okRate := deployCensusPct(none); okRate {
		t.Error("a node without pct must never yield a percentage")
	}
}
