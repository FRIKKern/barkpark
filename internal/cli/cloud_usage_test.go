package cli

// cloud_usage_test.go proves `bp cloud usage` against a fake control plane: the
// meter-name/label vocabulary is held to the committed usage_meters.json fixture
// (the OC8 drift tripwire — the SAME file the SPA slice asserts, so the two
// surfaces can never diverge), the table renders both the v1 all-unmetered shape
// and a mixed metered envelope honestly (formatted numbers, "as of" freshness,
// the pending-invitations footnote), `-o json` is the envelope BYTES verbatim,
// the team-scoped 404 maps to the no-existence-leak sentence, and the STATE cell
// paints through the shared statusRole seam.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// usageMetersCLIFixturePath is the shared meter-vocabulary fixture, read
// relative to internal/cli/ exactly like verify_probes.json.
var usageMetersCLIFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "usage_meters.json")

// TestUsageMeterVocabularyMatchesFixture holds the CLI's meter order + human
// labels to the committed fixture: same names, same order, same labels. A meter
// rename/reorder/relabel reds here — and if the SPA later asserts the same file,
// drift between the two surfaces is impossible.
func TestUsageMeterVocabularyMatchesFixture(t *testing.T) {
	raw, err := os.ReadFile(usageMetersCLIFixturePath)
	if err != nil {
		t.Fatalf("read usage_meters.json fixture: %v", err)
	}
	var fx struct {
		Meters []struct {
			Name  string `json:"name"`
			Label string `json:"label"`
		} `json:"meters"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode usage_meters.json: %v", err)
	}
	if len(fx.Meters) != len(usageMeterOrder) {
		t.Fatalf("fixture has %d meters, CLI order has %d", len(fx.Meters), len(usageMeterOrder))
	}
	if len(fx.Meters) != len(usageMeterLabels) {
		t.Fatalf("fixture has %d meters, CLI labels map has %d", len(fx.Meters), len(usageMeterLabels))
	}
	for i, m := range fx.Meters {
		if m.Name != usageMeterOrder[i] {
			t.Errorf("meter %d: fixture %q, CLI order %q", i, m.Name, usageMeterOrder[i])
		}
		if got := usageMeterLabels[m.Name]; got != m.Label {
			t.Errorf("%s: CLI label %q, fixture label %q", m.Name, got, m.Label)
		}
		if got := usageMeterLabel(m.Name); got != m.Label {
			t.Errorf("%s: usageMeterLabel = %q, fixture label %q", m.Name, got, m.Label)
		}
	}
}

// usageAllUnmeteredEnvelope is the v1 shape: every source unmetered but seats
// (a control-plane read that returns even when the box is down). This is what
// ships TODAY, before C11 lights up the instance counts.
const usageAllUnmeteredEnvelope = `{"usage":{"meters":{` +
	`"documents":{"value":"unmetered","quota":null,"warn_at":null,"source":"instance.documents","measured_at":null},` +
	`"datasets":{"value":"unmetered","quota":null,"warn_at":null,"source":"instance.datasets","measured_at":null},` +
	`"webhooks":{"value":"unmetered","quota":null,"warn_at":null,"source":"instance.webhooks.production","measured_at":null},` +
	`"db_size":{"value":"unmetered","quota":null,"warn_at":null,"source":"telemetry.pg_size_bytes","measured_at":null},` +
	`"disk":{"value":"unmetered","quota":null,"warn_at":null,"source":"telemetry.disk_used_percent","measured_at":null},` +
	`"seats":{"value":2,"quota":null,"warn_at":null,"source":"control-plane.team_members","measured_at":null,"pending_invitations":0},` +
	`"api_requests":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null},` +
	`"bandwidth":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null}}}}`

// usageMixedEnvelope is a live box: instance + telemetry meters reporting real
// numbers, a telemetry snapshot time, and a pending invitation on seats.
const usageMixedEnvelope = `{"usage":{"meters":{` +
	`"documents":{"value":128,"quota":null,"warn_at":null,"source":"instance.documents","measured_at":null},` +
	`"datasets":{"value":"unmetered","quota":null,"warn_at":null,"source":"instance.datasets","measured_at":null},` +
	`"webhooks":{"value":3,"quota":null,"warn_at":null,"source":"instance.webhooks.production","measured_at":null},` +
	`"db_size":{"value":4194304,"quota":null,"warn_at":null,"source":"telemetry.pg_size_bytes","measured_at":"2026-07-08T04:00:00Z"},` +
	`"disk":{"value":42,"quota":null,"warn_at":null,"source":"telemetry.disk_used_percent","measured_at":"2026-07-08T04:00:00Z"},` +
	`"seats":{"value":2,"quota":null,"warn_at":null,"source":"control-plane.team_members","measured_at":null,"pending_invitations":1},` +
	`"api_requests":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null},` +
	`"bandwidth":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null}}}}`

// newUsageServer stands up a fake control plane answering the usage route with
// the given status + body, seeds a cloud login pointed at it, and records the
// method/path/auth it saw.
func newUsageServer(t *testing.T, status int, body string) (gotMethod, gotPath, gotAuth *string) {
	t.Helper()
	var m, p, a string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, p, a = r.Method, r.URL.Path, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &p, &a
}

// runUsage drives runCloudUsage with an in-memory writer at the chosen output +
// color, returning stdout, stderr, exit.
func runUsage(t *testing.T, output string, color bool, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = color
	code := runCloudUsage(w, globals{}, args)
	return sout.String(), serr.String(), code
}

// TestRunCloudUsageAllUnmetered: the v1 shape renders every meter label with an
// honest "unmetered" state + its source label, exits 0, and the request is a
// Bearer-authed GET to the usage route (a UUID instance needs no fleet resolve).
func TestRunCloudUsageAllUnmetered(t *testing.T) {
	method, path, auth := newUsageServer(t, 200, usageAllUnmeteredEnvelope)

	stdout, stderr, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "GET" || *path != "/v1/barkparks/"+testInstanceID+"/usage" {
		t.Fatalf("hit %s %s, want GET /v1/barkparks/%s/usage", *method, *path, testInstanceID)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
	for _, label := range []string{"Documents", "Datasets", "Webhooks", "DB size", "Disk", "Seats", "API requests", "Bandwidth"} {
		if !strings.Contains(stdout, label) {
			t.Fatalf("missing meter label %q:\n%s", label, stdout)
		}
	}
	if !strings.Contains(stdout, "unmetered") {
		t.Fatalf("an unmetered meter must render its honest state:\n%s", stdout)
	}
	// The source label of a quiet pipe must still be named (never a fake zero).
	if !strings.Contains(stdout, "instance.documents") {
		t.Fatalf("a degraded meter must still name its source:\n%s", stdout)
	}
}

// TestRunCloudUsageMetered: a live envelope renders formatted numbers (count,
// human bytes, percent), the "as of" freshness note, the "live" state, and the
// pending-invitations footnote.
func TestRunCloudUsageMetered(t *testing.T) {
	newUsageServer(t, 200, usageMixedEnvelope)

	stdout, _, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, want := range []string{
		"128",                        // documents count
		"3",                          // webhook count
		"4.0 MB",                     // db_size 4194304 bytes → 4.0 MB
		"42%",                        // disk percent
		"live",                       // a metered STATE token
		"as of 2026-07-08T04:00:00Z", // db_size freshness
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("metered render missing %q:\n%s", want, stdout)
		}
	}
	if !strings.Contains(stdout, "1 pending invitation(s)") {
		t.Fatalf("the pending-invitations footnote must show:\n%s", stdout)
	}
	// datasets stays unmetered in this envelope — the row is honest per-meter.
	if !strings.Contains(stdout, "instance.datasets") {
		t.Fatalf("the still-unmetered datasets source must render:\n%s", stdout)
	}
	// An unmetered meter has no reading, so it claims no freshness: its AS OF is a
	// dash, never "live" (a quiet pipe never poses as a current read — the same
	// no-fake-reading honesty its dashed VALUE cell carries).
	datasetsRow := usageTestRow(t, stdout, "Datasets")
	if strings.Contains(datasetsRow, "live") {
		t.Fatalf("an unmetered meter's AS OF must not claim a live read:\n%s", datasetsRow)
	}
	if !strings.Contains(datasetsRow, "—") {
		t.Fatalf("an unmetered meter's AS OF must dash out:\n%s", datasetsRow)
	}
}

// usageTestRow returns the single rendered meter row whose METER label is the
// given prefix, failing the test if it is absent.
func usageTestRow(t *testing.T, out, label string) string {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, label) {
			return line
		}
	}
	t.Fatalf("no rendered row for meter %q:\n%s", label, out)
	return ""
}

// TestRunCloudUsageJSONPassthrough: `-o json` emits the control-plane envelope
// BYTES verbatim (the envelope IS the contract) and exits 0.
func TestRunCloudUsageJSONPassthrough(t *testing.T) {
	newUsageServer(t, 200, usageMixedEnvelope)
	stdout, _, code := runUsage(t, "json", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if stdout != usageMixedEnvelope+"\n" {
		t.Fatalf("json output must be the envelope verbatim:\n got: %q\nwant: %q", stdout, usageMixedEnvelope+"\n")
	}
}

// TestRunCloudUsageNotFound: the team-scoped 404 maps to the no-existence-leak
// sentence, exit not_found, stdout clean.
func TestRunCloudUsageNotFound(t *testing.T) {
	newUsageServer(t, 404, `{"error":"not_found"}`)
	stdout, stderr, code := runUsage(t, "table", false, testInstanceID)
	if code != exitNotFound {
		t.Fatalf("exit = %d, want %d (not_found)", code, exitNotFound)
	}
	if !strings.Contains(stderr, "no such instance") {
		t.Fatalf("want the no-such-instance sentence:\n%s", stderr)
	}
	if strings.TrimSpace(stdout) != "" {
		t.Fatalf("a refusal must keep stdout clean on the human path:\n%s", stdout)
	}
}

// TestRunCloudUsageNoToken: without a Cloud session the command is an auth error
// with a `bp login` hint and makes no network call.
func TestRunCloudUsageNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runUsage(t, "table", false, testInstanceID)
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !strings.Contains(stderr, "bp login") {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudUsageUsage: zero or extra positionals (and unknown flags) are
// usage errors, exit 2.
func TestRunCloudUsageUsage(t *testing.T) {
	withTempConfigHome(t)
	if _, _, code := runUsage(t, "table", false); code != exitUsage {
		t.Fatalf("no-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runUsage(t, "table", false, "a", "b"); code != exitUsage {
		t.Fatalf("two-arg exit = %d, want %d", code, exitUsage)
	}
	if _, _, code := runUsage(t, "table", false, "--bogus", "x"); code != exitUsage {
		t.Fatalf("unknown-flag exit = %d, want %d", code, exitUsage)
	}
}

// TestRunCloudUsageColorRoles: with color on, a metered STATE cell paints green
// through the shared statusRole seam, while the colorless run of the same
// envelope carries no ANSI at all (the D12 byte-identity guarantee).
func TestRunCloudUsageColorRoles(t *testing.T) {
	newUsageServer(t, 200, usageMixedEnvelope)
	colored, _, _ := runUsage(t, "table", true, testInstanceID)
	if !strings.Contains(colored, "\033[32m") {
		t.Fatalf("want a green (live) STATE cell in colored output:\n%q", colored)
	}

	newUsageServer(t, 200, usageMixedEnvelope)
	plain, _, _ := runUsage(t, "table", false, testInstanceID)
	if strings.Contains(plain, "\033[") {
		t.Fatalf("colorless output must carry no ANSI:\n%q", plain)
	}
}

// TestRunCloudUsageHelp: -h anywhere prints usage and exits 0 without a network
// call or a config requirement.
func TestRunCloudUsageHelp(t *testing.T) {
	withTempConfigHome(t)
	stdout, _, code := runUsage(t, "table", false, "-h")
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "bp cloud usage") {
		t.Fatalf("help must name the command:\n%s", stdout)
	}
}

// TestHumanBytes covers the byte formatter's unit boundaries directly — the
// db_size meter's display depends on it.
func TestHumanBytes(t *testing.T) {
	cases := []struct {
		in   float64
		want string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{4194304, "4.0 MB"},
		{1610612736, "1.5 GB"},
	}
	for _, c := range cases {
		if got := humanBytes(c.in); got != c.want {
			t.Errorf("humanBytes(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}
