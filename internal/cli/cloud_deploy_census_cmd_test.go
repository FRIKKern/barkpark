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
	if *method != "GET" || *path != "/v1/operator/deploy-ledger/census" {
		t.Fatalf("hit %s %s, want GET /v1/operator/deploy-ledger/census", *method, *path)
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

// TestCloudDeploymentsRefusals walks the three HTTP refusal states. Each must
// exit on the ladder, name what refused, and print NO count — a refusal that
// renders as "0 failed" is the exact defect this verb exists to prevent.
func TestCloudDeploymentsRefusals(t *testing.T) {
	cases := []struct {
		name     string
		status   int
		body     string
		wantExit int
		wantIn   []string
	}{
		{
			name:     "401 unauthorized",
			status:   401,
			body:     `{"error":"unauthorized"}`,
			wantExit: exitAuth,
			wantIn:   []string{"401 unauthorized", "NOT a fleet with zero failures", "bp login"},
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
				"PLATFORM_ADMIN_EMAILS",
				"cannot tell you which of the two it is",
			},
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
			if pctRe.MatchString(all) {
				t.Fatalf("a refusal must never render a percentage:\n%s", all)
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
