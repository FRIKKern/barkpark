package agent

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// The agent's health_status is what the fleet dashboard colours, so the two
// control arms have to hold at THIS layer too, not just inside the gate:
//
//   - a healthy box whose optional stubs never ran must report "up", and must
//     carry the skips through as skips so the control plane can count them
//     apart from passes;
//   - a genuinely failing check must still report "down". A fleet-wide false
//     "down" (azh-agent-healthgate-down-finding) is fixed by making unreadable
//     checks abstain — never by making the gate incapable of saying down.

func gateReturning(report setup.HealthReport, err error) func(string, string, setup.HealthGate) (setup.HealthReport, error) {
	return func(string, string, setup.HealthGate) (setup.HealthReport, error) { return report, err }
}

func TestHealthStatusIsUpWhenOnlyOptionalStubsWereSkipped(t *testing.T) {
	report := setup.HealthReport{
		BaseURL: "https://server.example.com",
		OK:      true,
		Checks: []setup.CheckResult{
			{Name: "capabilities", Pass: true, Status: setup.CheckPass, Detail: "200"},
			{Name: "studio", Pass: true, Status: setup.CheckPass, Detail: "200"},
			{Name: "websocket-not-403", Pass: true, Status: setup.CheckPass, Detail: "101"},
			{Name: "tls", Pass: true, Status: setup.CheckPass, Detail: "verified"},
			{Name: "postgres-via-api", Pass: true, Status: setup.CheckPass, Detail: "operational"},
			{Name: "agent-connected-stub", Pass: true, Status: setup.CheckSkip, Detail: "NOT CHECKED"},
			{Name: "backup-scheduled-stub", Pass: true, Status: setup.CheckSkip, Detail: "NOT CHECKED"},
		},
	}
	r := gatherReport(ReportConfig{
		HealthBaseURL:    "https://server.example.com",
		runHealthGateFor: gateReturning(report, nil),
	})

	if r.HealthStatus != "up" {
		t.Fatalf("HealthStatus = %q, want up — a healthy box with two unprobed optional stubs is not down", r.HealthStatus)
	}

	// Positive control on the payload: the per-check detail the control plane
	// records must actually contain the five checks that RAN, or "up" would be
	// asserting over nothing.
	var ran, skipped int
	for _, c := range r.Health {
		switch c.Effective() {
		case setup.CheckPass:
			ran++
		case setup.CheckSkip:
			skipped++
		}
	}
	if ran != 5 {
		t.Errorf("expected 5 checks to have run and passed in the payload, got %d", ran)
	}
	if skipped != 2 {
		t.Errorf("expected the 2 optional stubs to ride as skips, got %d", skipped)
	}
}

func TestHealthStatusIsStillDownForAGenuineFailure(t *testing.T) {
	// The negative arm. If this ever goes green the health signal has become
	// decorative: nothing would be able to mark a box down again.
	report := setup.HealthReport{
		BaseURL: "https://server.example.com",
		OK:      false,
		Checks: []setup.CheckResult{
			{Name: "capabilities", Pass: true, Status: setup.CheckPass, Detail: "200"},
			{Name: "websocket-not-403", Pass: false, Status: setup.CheckFail, Detail: "403 — check_origin drift"},
			{Name: "agent-connected-stub", Pass: true, Status: setup.CheckSkip, Detail: "NOT CHECKED"},
		},
	}
	r := gatherReport(ReportConfig{
		HealthBaseURL:    "https://server.example.com",
		runHealthGateFor: gateReturning(report, errGateFailed{}),
	})

	if r.HealthStatus != "down" {
		t.Fatalf("HealthStatus = %q, want down — a red websocket is a real outage and a skip must not rescue it", r.HealthStatus)
	}
	var failing int
	for _, c := range r.Health {
		if c.Effective() == setup.CheckFail {
			failing++
		}
	}
	if failing != 1 {
		t.Errorf("expected exactly the websocket failure to ride in the payload, got %d failing", failing)
	}
}

func TestHealthStatusIsUnknownWhenNoGateWasWired(t *testing.T) {
	// The third state at the report layer, which already existed and must not
	// regress: no probe wired is not a claim in either direction.
	r := gatherReport(ReportConfig{})
	if r.HealthStatus != "unknown" {
		t.Fatalf("HealthStatus = %q, want unknown when no health base URL is configured", r.HealthStatus)
	}
}

type errGateFailed struct{}

func (errGateFailed) Error() string { return "health gate failed: websocket-not-403 not ready" }
