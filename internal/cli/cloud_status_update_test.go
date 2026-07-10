package cli

// cloud_status_update_test.go proves the isu-w5 self-update TRUTH that `bp cloud
// status` now surfaces: the UPDATE (running → latest) / CHANNEL / POLICY columns
// light up when the control plane reports them, stay OFF for an older CP (so the
// table is byte-identical to before), the policy cell collapses to the right
// compact flag, and a representative row stays readable at 80 columns. The pure
// updateCell / policyCell helpers are pinned directly.

import (
	"bytes"
	"strings"
	"testing"

	"github.com/mattn/go-runewidth"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

func boolPtr(b bool) *bool { return &b }

func TestUpdateCell(t *testing.T) {
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"absent → empty (older CP)", cloudclient.Barkpark{}, ""},
		{"behind by version delta", cloudclient.Barkpark{UpdateRunningRelease: "1.4.2", UpdateLatestRelease: "1.5.0"}, "1.4.2 → 1.5.0"},
		{"behind by verdict, running known", cloudclient.Barkpark{UpdateRunningRelease: "1.4.2", UpdateLatestRelease: "1.5.0", UpdateState: "behind"}, "1.4.2 → 1.5.0"},
		{"current shows running only", cloudclient.Barkpark{UpdateRunningRelease: "1.5.0", UpdateLatestRelease: "1.5.0"}, "1.5.0"},
		{"only running known", cloudclient.Barkpark{UpdateRunningRelease: "1.5.0"}, "1.5.0"},
		{"only latest known", cloudclient.Barkpark{UpdateLatestRelease: "1.5.0"}, "1.5.0"},
	}
	for _, c := range cases {
		if got := updateCell(c.bp); got != c.want {
			t.Errorf("%s: updateCell = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestPolicyCell(t *testing.T) {
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"unknown policy (older CP) → empty", cloudclient.Barkpark{}, ""},
		{"pin wins over everything", cloudclient.Barkpark{PinnedRelease: "v1.2", AutoupdatePaused: true, AutoupdateEnabled: boolPtr(false)}, "pin@v1.2"},
		{"paused over off", cloudclient.Barkpark{AutoupdatePaused: true, AutoupdateEnabled: boolPtr(false)}, "paused"},
		{"explicit off", cloudclient.Barkpark{AutoupdateEnabled: boolPtr(false)}, "off"},
		{"auto default", cloudclient.Barkpark{AutoupdateEnabled: boolPtr(true)}, "auto"},
	}
	for _, c := range cases {
		if got := policyCell(c.bp); got != c.want {
			t.Errorf("%s: policyCell = %q, want %q", c.name, got, c.want)
		}
	}
}

// renderStatusToString runs the bucket render for one row-set and returns the
// plain (no-color) text.
func renderStatusToString(rows []rankedBarkpark) string {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusRows(w, rows)
	return sout.String()
}

// TestStatusColumnsDarkForOlderCP: with no self-update fields, the new columns
// must NOT appear — the older-CP path is byte-identical to the legacy table.
func TestStatusColumnsDarkForOlderCP(t *testing.T) {
	rows := rankBarkparks([]cloudclient.Barkpark{
		{Name: "prod", Host: "h", HealthStatus: "up", AgentStatus: "online", URL: "https://prod.barkpark.cloud"},
	})
	out := renderStatusToString(rows)
	for _, col := range []string{"UPDATE", "CHANNEL", "POLICY"} {
		if strings.Contains(out, col) {
			t.Fatalf("older-CP table should not show %q column:\n%s", col, out)
		}
	}
	if !strings.Contains(out, "STATUS") || !strings.Contains(out, "URL") {
		t.Fatalf("legacy columns missing:\n%s", out)
	}
}

// TestStatusColumnsLightUpWithTruth: a behind box with channel + pin shows all
// three new columns, the running→latest delta, the channel, and the compact pin.
func TestStatusColumnsLightUpWithTruth(t *testing.T) {
	rows := rankBarkparks([]cloudclient.Barkpark{
		{
			Name: "mkt", Host: "h", HealthStatus: "up", AgentStatus: "online",
			URL:                  "https://mkt.barkpark.cloud",
			UpdateState:          "behind",
			UpdateRunningRelease: "1.4.2", UpdateLatestRelease: "1.5.0",
			Channel: "canary", PinnedRelease: "1.4.2", AutoupdateEnabled: boolPtr(true),
		},
	})
	out := renderStatusToString(rows)
	for _, want := range []string{"UPDATE", "CHANNEL", "POLICY", "1.4.2 → 1.5.0", "canary", "pin@1.4.2"} {
		if !strings.Contains(out, want) {
			t.Fatalf("truth table missing %q:\n%s", want, out)
		}
	}
}

// TestStatusReadableAt80: the columns this feature ADDS (UPDATE · CHANNEL ·
// POLICY) stay compact — a behind row with all three active, worst-case pinned
// policy, fits within 80 columns once the inherently-unbounded URL is set aside.
// URL is deliberately the LAST column, so it is the only field that can push a
// row past 80 — exactly as the legacy STATUS table already behaved. We prove the
// new chrome doesn't itself blow the budget by rendering with URL/Host blank (the
// URL cell collapses to a dash).
func TestStatusReadableAt80(t *testing.T) {
	rows := rankBarkparks([]cloudclient.Barkpark{
		{
			Name: "marketing", HealthStatus: "up", AgentStatus: "online",
			// No URL/Host → the URL cell is a dash, isolating the added chrome.
			UpdateState:          "behind",
			UpdateRunningRelease: "1.4.2", UpdateLatestRelease: "1.5.0",
			Channel: "canary", PinnedRelease: "1.4.2", AutoupdateEnabled: boolPtr(true),
		},
	})
	out := renderStatusToString(rows)
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if w := runewidth.StringWidth(line); w > 80 {
			t.Fatalf("added columns exceed 80 cols (%d) before URL: %q", w, line)
		}
	}
}

// TestStatusJSONCarriesTruth: -o json emits the self-update fields, and
// autoupdate_enabled is TRI-STATE — present when the CP reported it, ABSENT when
// it didn't (never a fake false for an older CP).
func TestStatusJSONCarriesTruth(t *testing.T) {
	withEnabled := rankBarkparks([]cloudclient.Barkpark{
		{Name: "a", Host: "h", HealthStatus: "up", AgentStatus: "online", AutoupdateEnabled: boolPtr(false), PinnedRelease: "v9", Channel: "stable", UpdateRunningRelease: "1.0.0", UpdateLatestRelease: "1.1.0"},
	})
	row := rankedBarkparkRow(withEnabled[0])
	if row["autoupdate_enabled"] != false {
		t.Fatalf("autoupdate_enabled = %v, want present false", row["autoupdate_enabled"])
	}
	if row["pinned_release"] != "v9" || row["channel"] != "stable" || row["update_latest_release"] != "1.1.0" {
		t.Fatalf("row missing truth fields: %v", row)
	}

	absent := rankBarkparks([]cloudclient.Barkpark{
		{Name: "b", Host: "h", HealthStatus: "up", AgentStatus: "online"}, // older CP: no policy
	})
	rowB := rankedBarkparkRow(absent[0])
	if _, present := rowB["autoupdate_enabled"]; present {
		t.Fatalf("autoupdate_enabled must be ABSENT for an older CP, got %v", rowB["autoupdate_enabled"])
	}
}
