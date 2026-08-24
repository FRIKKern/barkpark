package setup

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The three-state contract: a check that DID NOT RUN is neither a pass nor a
// failure, and the report has to say so.
//
// Both collapses have shipped on this gate. Before StubsOptional, an unwired
// stub was a FAIL, so every online box reported health_status=down fleet-wide
// (azh-agent-healthgate-down-finding) and the health signal became noise. The
// fix flipped it to a PASS, which is the mirror-image lie: the gate then
// printed "all 7 checks passed" while two of the seven were never probed.
//
// These tests pin both arms — a genuinely broken box must still read broken,
// and a healthy box must read healthy WITHOUT the report claiming it verified
// things it skipped.

// --- negative control: the gate can still call a box down -------------------

func TestSkipsDoNotRescueAGenuinelyBrokenBox(t *testing.T) {
	// The cheapest way to fix "everything reports down" is to make nothing ever
	// report down. This is the arm that forbids it: the box is genuinely broken
	// (the websocket-403 footgun) AND has two skipped stubs, and it must still
	// come out NOT READY naming the real failing check.
	ov := allGreenOverrides()
	ov["/live/websocket"] = http.StatusForbidden
	srv := httptest.NewTLSServer(statusHandler(http.StatusOK, ov))
	defer srv.Close()

	report, err := RunHealthGate(srv.URL, "tok", HealthGate{
		RootCAs:          poolFor(srv),
		PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		StubsOptional:    true,
	})
	if err == nil {
		t.Fatalf("a red websocket must fail the gate even with two skipped stubs\n%s", report)
	}
	if report.OK {
		t.Fatalf("report.OK must be false for a genuinely broken box\n%s", report)
	}
	if got := report.Failures(); len(got) != 1 || got[0] != "websocket-not-403" {
		t.Fatalf("expected exactly the websocket-not-403 failure, got %v\n%s", got, report)
	}
	// The skips must still be reported — and must not have been quietly folded
	// into the failure list, which would make the operator chase the wrong box.
	if got := report.Skipped(); len(got) != 2 {
		t.Fatalf("expected the 2 unwired stubs to be skipped, got %v\n%s", got, report)
	}
	if s := report.String(); !strings.Contains(s, "NOT READY") {
		t.Fatalf("a broken box must render NOT READY, got:\n%s", s)
	}
}

func TestAGenuineStubFailureIsAFailureNotASkip(t *testing.T) {
	// A stub that IS wired and answers badly ran and did not hold. StubsOptional
	// governs only the UNWIRED case — it must never launder a live 500 into an
	// abstention, or a broken agent endpoint would be indistinguishable from one
	// nobody configured.
	srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
	defer srv.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer bad.Close()

	report, err := RunHealthGate(srv.URL, "tok", HealthGate{
		RootCAs:          poolFor(srv),
		PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		AgentStatusURL:   bad.URL,
		StubsOptional:    true,
	})
	if err == nil || report.OK {
		t.Fatalf("a wired agent stub returning 500 must fail the gate\n%s", report)
	}
	if got := report.Failures(); len(got) != 1 || got[0] != "agent-connected-stub" {
		t.Fatalf("expected the wired agent stub to FAIL, got %v\n%s", got, report)
	}
	if got := report.Skipped(); len(got) != 1 || got[0] != "backup-scheduled-stub" {
		t.Fatalf("only the still-unwired backup stub may be skipped, got %v\n%s", got, report)
	}
}

func TestMandatoryUnwiredStubIsAFailureNotASkip(t *testing.T) {
	// Without StubsOptional the caller has declared this wiring REQUIRED before
	// go-live. "You were required to configure this and did not" is an
	// actionable failure of the operator's contract, not an abstention — so it
	// must stay red rather than disappear into the skip bucket.
	g := HealthGate{}
	for _, c := range []CheckResult{g.checkAgentConnected(), g.checkBackupScheduled()} {
		if c.Effective() != CheckFail {
			t.Errorf("%s: a required-but-unwired stub must be CheckFail, got %q", c.Name, c.Effective())
		}
	}
}

// --- positive control: a healthy box reads healthy, honestly ----------------

func TestHealthyBoxWithUnwiredStubsIsReadyAndSaysWhatItSkipped(t *testing.T) {
	// The shape every live agent beat and every warm-pool go-live actually runs:
	// a genuinely healthy server with the two cloud-9/10 stubs unwired.
	srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
	defer srv.Close()

	report, err := RunHealthGate(srv.URL, "tok", HealthGate{
		RootCAs:          poolFor(srv),
		PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		StubsOptional:    true,
	})
	if err != nil || !report.OK {
		t.Fatalf("a healthy box with optional stubs unwired must be READY: err=%v\n%s", err, report)
	}

	// Positive control on the instrument itself: this gate must actually have
	// EXERCISED the real checks. A checker that reports nothing would satisfy
	// every "no failures" assertion above while proving nothing at all.
	passed := report.Passed()
	if len(passed) == 0 {
		t.Fatalf("no check passed — the gate cannot have run; %s", report)
	}
	for _, want := range []string{"capabilities", "studio", "websocket-not-403", "tls", "postgres-via-api"} {
		if !containsName(passed, want) {
			t.Errorf("check %q must have RUN and passed against the all-green server; passed=%v", want, passed)
		}
	}

	// And the skips must be named, not silently counted as verified.
	skipped := report.Skipped()
	if len(skipped) != 2 || !containsName(skipped, "agent-connected-stub") || !containsName(skipped, "backup-scheduled-stub") {
		t.Fatalf("expected the 2 unwired stubs in Skipped(), got %v\n%s", skipped, report)
	}
	for _, name := range skipped {
		if containsName(passed, name) {
			t.Errorf("%q was skipped but also counted as passed — a probe that did not run must not vote", name)
		}
	}
	if len(passed)+len(skipped)+len(report.Failures()) != len(report.Checks) {
		t.Errorf("the three buckets must partition the checks: %d pass + %d skip + %d fail != %d total",
			len(passed), len(skipped), len(report.Failures()), len(report.Checks))
	}
}

func TestReportNeverClaimsAllChecksPassedWhenSomeWereSkipped(t *testing.T) {
	// The one-sentence version of the bug: "READY (all 7 checks passed)" over a
	// run that probed five. The rendered roll-up is what an operator reads, so
	// the honesty has to survive into the string, not live only in a field.
	srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
	defer srv.Close()

	report, _ := RunHealthGate(srv.URL, "tok", HealthGate{
		RootCAs:          poolFor(srv),
		PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		StubsOptional:    true,
	})
	s := report.String()
	if strings.Contains(s, "all 7 checks passed") {
		t.Fatalf("the roll-up claims 7 checks passed but 2 never ran:\n%s", s)
	}
	if !strings.Contains(s, "NOT CHECKED") {
		t.Fatalf("a green report with skips must name them as NOT CHECKED:\n%s", s)
	}
	if !strings.Contains(s, "[SKIP]") {
		t.Fatalf("a skipped check must render its own marker, not PASS:\n%s", s)
	}
	if !strings.Contains(s, "READY") {
		t.Fatalf("the box is healthy — it must still read READY:\n%s", s)
	}
}

func TestAllChecksPassedIsStillPrintedWhenNothingWasSkipped(t *testing.T) {
	// The counterpart: when every probe really did run, the report must keep
	// saying so. A fix that simply deleted the confident sentence would be a
	// different kind of unhelpful.
	srv := httptest.NewTLSServer(statusHandler(http.StatusOK, allGreenOverrides()))
	defer srv.Close()
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer stub.Close()

	report, err := RunHealthGate(srv.URL, "tok", HealthGate{
		RootCAs:          poolFor(srv),
		PostgresProbeURL: srv.URL + "/w/default/p/default/v1/data/query/production/post",
		AgentStatusURL:   stub.URL,
		BackupStatusURL:  stub.URL,
	})
	if err != nil || !report.OK {
		t.Fatalf("fully wired healthy box must be READY: err=%v\n%s", err, report)
	}
	if len(report.Skipped()) != 0 {
		t.Fatalf("nothing should be skipped when every probe is wired, got %v", report.Skipped())
	}
	if s := report.String(); !strings.Contains(s, "all 7 checks passed") {
		t.Fatalf("a fully-probed green gate must still say all checks passed:\n%s", s)
	}
}

// --- wire compatibility and the unset-Status fallback -----------------------

func TestSkipKeepsItsHistoricalWireBytes(t *testing.T) {
	// The Cloud control plane's Telemetry.summarize_checks reads `pass`. Older
	// deployments of it must see EXACTLY what they saw before `status` existed,
	// so shipping this cannot move any existing roll-up; `status` is the channel
	// a reader opts into.
	for _, tc := range []struct {
		name       string
		c          CheckResult
		wantPass   bool
		wantStatus string
	}{
		{"skip", skipCheck("agent-connected-stub", "d"), true, "skip"},
		{"pass", passCheck("capabilities", "d"), true, "pass"},
		{"fail", failCheck("websocket-not-403", "d"), false, "fail"},
	} {
		b, err := json.Marshal(tc.c)
		if err != nil {
			t.Fatalf("%s: marshal: %v", tc.name, err)
		}
		var got struct {
			Pass   bool   `json:"pass"`
			Status string `json:"status"`
		}
		if err := json.Unmarshal(b, &got); err != nil {
			t.Fatalf("%s: unmarshal: %v", tc.name, err)
		}
		if got.Pass != tc.wantPass {
			t.Errorf("%s: legacy `pass` = %v, want %v (an old reader's roll-up must not move)", tc.name, got.Pass, tc.wantPass)
		}
		if got.Status != tc.wantStatus {
			t.Errorf("%s: `status` = %q, want %q", tc.name, got.Status, tc.wantStatus)
		}
	}
}

func TestUnsetStatusFallsBackToPassNeverToSkip(t *testing.T) {
	// A CheckResult built outside this package — a test literal, a caller
	// compiled against the previous struct — has an empty Status. It must keep
	// its original two-state meaning: silently reading it as an abstention would
	// excuse a real failure from the count, which is the exact class of bug this
	// change exists to remove.
	if got := (CheckResult{Name: "x", Pass: true}).Effective(); got != CheckPass {
		t.Errorf("unset Status with Pass=true must read CheckPass, got %q", got)
	}
	if got := (CheckResult{Name: "x", Pass: false}).Effective(); got != CheckFail {
		t.Errorf("unset Status with Pass=false must read CheckFail, got %q", got)
	}

	// And a report built entirely from such literals must roll up the old way.
	r := HealthReport{Checks: []CheckResult{{Name: "a", Pass: true}, {Name: "b", Pass: false}}}
	if got := r.Failures(); len(got) != 1 || got[0] != "b" {
		t.Errorf("legacy literals: Failures() = %v, want [b]", got)
	}
	if got := r.Skipped(); len(got) != 0 {
		t.Errorf("legacy literals can never be skips, got %v", got)
	}
}

func containsName(xs []string, want string) bool {
	for _, x := range xs {
		if x == want {
			return true
		}
	}
	return false
}
