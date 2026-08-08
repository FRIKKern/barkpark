package cli

// cloud_usage_unavailable_test.go covers the THIRD meter state the CLI used to
// lose on the floor: a read that was ATTEMPTED and FAILED.
//
// The control plane has always distinguished it — Usage.unavailable_meter/2
// attaches a typed `unavailable_reason` from a CLOSED allowlist (exception,
// deadline_exceeded, unreachable, bad_shape, too_many_datasets) — but
// cloudclient.UsageMeter carried no field for it, so the reason died at
// UNMARSHAL one layer below the renderer and a crashed meter rendered in the
// product's own words for a deliberate non-measurement. Worse, the fleet row
// roll-up had no severity rung for it, so a box whose headline meter had
// CRASHED could roll up no worse than one that was merely never sampled.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// usageUnavailableEnvelope: documents CRASHED (unreachable), datasets is
// deliberately not metered, db_size is a real number. The three states, side by
// side, in one envelope — exactly the mix an operator meets on a sick box.
const usageUnavailableEnvelope = `{"usage":{"meters":{` +
	`"documents":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.documents","measured_at":null,"unavailable_reason":"unreachable"},` +
	`"datasets":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.datasets","measured_at":null},` +
	`"webhooks":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.webhooks","measured_at":null,"unavailable_reason":"deadline_exceeded"},` +
	`"db_size":{"value":3525639191,"quota":null,"warn_at":null,"over_at":null,"source":"telemetry.pg_size_bytes","measured_at":"2026-08-06T12:57:30Z"},` +
	`"disk":{"value":76,"quota":100,"warn_at":70,"over_at":90,"source":"telemetry.disk_used_percent","measured_at":"2026-08-06T12:57:30Z"},` +
	`"seats":{"value":2,"quota":null,"warn_at":null,"over_at":null,"source":"control-plane.team_members","measured_at":null},` +
	`"api_requests":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"not-metered","measured_at":null},` +
	`"bandwidth":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"not-metered","measured_at":null}}}}`

// TestUsageMeterCarriesUnavailableReason: the reason survives the round trip
// through the client struct. Without the field it decoded to "" and every
// downstream honesty was impossible.
func TestUsageMeterCarriesUnavailableReason(t *testing.T) {
	// Decode through the SAME struct the renderer reads.
	var m cloudclient.UsageMeter
	raw := `{"value":"unmetered","source":"instance.documents","unavailable_reason":"unreachable"}`
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if m.UnavailableReason != "unreachable" {
		t.Fatalf("UnavailableReason=%q — the typed reason died at unmarshal", m.UnavailableReason)
	}
	// It is a CONDITIONAL key (the PendingInvitations precedent): a healthy meter
	// carries no reason at all.
	var healthy cloudclient.UsageMeter
	if err := json.Unmarshal([]byte(`{"value":5,"source":"control-plane.team_members"}`), &healthy); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if healthy.UnavailableReason != "" {
		t.Fatalf("a healthy meter must carry no reason, got %q", healthy.UnavailableReason)
	}
}

// TestUsageStateTokenThirdState: a failed read is "unavailable", a deliberate
// non-measurement stays "unmetered", and a real reading stays "live".
func TestUsageStateTokenThirdState(t *testing.T) {
	crashed := cloudclient.UsageMeter{Value: "unmetered", Source: "instance.documents", UnavailableReason: "unreachable"}
	if got := usageStateToken(crashed, true); got != "unavailable" {
		t.Fatalf("a CRASHED meter reads %q — it must not borrow the deliberate 'unmetered' word", got)
	}
	dark := cloudclient.UsageMeter{Value: "unmetered", Source: "instance.datasets"}
	if got := usageStateToken(dark, true); got != "unmetered" {
		t.Fatalf("a deliberately-dark meter reads %q want unmetered", got)
	}
	live := cloudclient.UsageMeter{Value: float64(5), Source: "control-plane.team_members"}
	if got := usageStateToken(live, true); got != "live" {
		t.Fatalf("a metered meter reads %q want live", got)
	}
	// An ABSENT meter (not in the envelope at all) has no reason to report.
	if got := usageStateToken(cloudclient.UsageMeter{}, false); got != "unmetered" {
		t.Fatalf("an absent meter reads %q want unmetered", got)
	}
}

// TestUsageStateSeverityRanksFailedReads: the rung the roll-up lacked. A crashed
// headline meter must outrank a merely-dark one, or a sick box rolls up calm.
func TestUsageStateSeverityRanksFailedReads(t *testing.T) {
	if usageStateSeverity("unavailable") <= usageStateSeverity("unmetered") {
		t.Fatal("a FAILED read must outrank a deliberate non-measurement in the roll-up")
	}
	if usageStateSeverity("unavailable") <= usageStateSeverity("live") {
		t.Fatal("a FAILED read must outrank a healthy meter")
	}
	// A known breach still outranks blindness — the ordering above it is intact.
	if usageStateSeverity("near_limit") <= usageStateSeverity("unavailable") ||
		usageStateSeverity("over_limit") <= usageStateSeverity("near_limit") {
		t.Fatal("over_limit > near_limit > unavailable must hold")
	}
}

// TestUsageStateSeverityUnknownTokenFailsClosed mirrors
// cloud_status_cmd_test.go's attentionBucket("some_future_rung") == "attention"
// pin: the roll-up's default arm had NO test, so an unranked state silently
// landed on the healthy floor. An unknown is BLIND (above "live") but not
// TRIPPED (below over_limit) — it must not fake a breach either.
func TestUsageStateSeverityUnknownTokenFailsClosed(t *testing.T) {
	if usageStateSeverity("some_future_rung") <= usageStateSeverity("live") {
		t.Error("an unranked state must NEVER roll a row up as healthy as a live meter")
	}
	if usageStateSeverity("some_future_rung") >= usageStateSeverity("over_limit") {
		t.Error("an unranked state is blind, not tripped — it must not outrank a real breach")
	}
}

// TestFleetRowStateSurfacesACrashedHeadlineMeter: the whole point — a row whose
// headline meter crashed can no longer roll up as if nothing happened.
func TestFleetRowStateSurfacesACrashedHeadlineMeter(t *testing.T) {
	healthy := map[string]cloudclient.UsageMeter{
		"documents": {Value: float64(12)},
		"db_size":   {Value: float64(1024)},
		"disk":      {Value: float64(10)},
		"seats":     {Value: float64(2)},
		"cpu":       {Value: float64(3)},
		"ram":       {Value: float64(40)},
	}
	if got := fleetRowState(healthy); got != "live" {
		t.Fatalf("a fully-reporting row = %q want live", got)
	}

	crashed := map[string]cloudclient.UsageMeter{}
	for k, v := range healthy {
		crashed[k] = v
	}
	crashed["documents"] = cloudclient.UsageMeter{Value: "unmetered", UnavailableReason: "exception"}
	if got := fleetRowState(crashed); got != "unavailable" {
		t.Fatalf("a row with a CRASHED headline meter = %q want unavailable", got)
	}

	// A merely-dark meter still reads unmetered, not unavailable — the two
	// stories stay distinct at the row level too.
	dark := map[string]cloudclient.UsageMeter{}
	for k, v := range healthy {
		dark[k] = v
	}
	dark["documents"] = cloudclient.UsageMeter{Value: "unmetered"}
	if got := fleetRowState(dark); got != "unmetered" {
		t.Fatalf("a row with a dark meter = %q want unmetered", got)
	}
}

// TestRunCloudUsageRendersTheThirdState drives the whole command: the operator
// sees WHICH pipe broke and WHY, beside a meter that is merely dark and a meter
// carrying a real number.
func TestRunCloudUsageRendersTheThirdState(t *testing.T) {
	newUsageServer(t, 200, usageUnavailableEnvelope)
	stdout, stderr, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	for _, want := range []string{
		"unavailable",                      // the STATE cell
		"instance.documents (unreachable)", // WHICH pipe, and WHY
		"instance.webhooks (deadline_exceeded)",
		"3.3 GB", // db_size is a real number now, not "unmetered"
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("usage output missing %q:\n%s", want, stdout)
		}
	}
	// The deliberately-dark meter keeps its own word and gains no fake reason.
	if strings.Contains(stdout, "instance.datasets (") {
		t.Fatalf("a deliberately-unmetered meter must carry no reason:\n%s", stdout)
	}
}
