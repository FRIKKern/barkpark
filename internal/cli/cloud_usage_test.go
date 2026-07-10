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
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
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
		// The per-instance human path also probes /usage/history (OC21). Answer it
		// 404 by default so the fail-soft branch drops the TREND column and these
		// goldens stay the pre-existing (history-free) table — the primary /usage
		// request is the one recorded. TREND tests use newUsageHistoryServer.
		if strings.HasSuffix(r.URL.Path, "/usage/history") {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":"not_found"}`))
			return
		}
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

// newUsageHistoryServer stands up a fake control plane that answers BOTH the
// per-instance /usage route (with usageBody) and its /usage/history route (with
// histStatus + histBody), so a TREND test can drive the two-fetch human path. It
// records the path of EACH request seen (in order) so a test can assert that the
// raw path makes no history call.
func newUsageHistoryServer(t *testing.T, usageBody string, histStatus int, histBody string) *[]string {
	t.Helper()
	paths := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		if strings.HasSuffix(r.URL.Path, "/usage/history") {
			w.WriteHeader(histStatus)
			_, _ = w.Write([]byte(histBody))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(usageBody))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &paths
}

// usageHistoryEnvelope is a mixed history payload for the TREND tests: documents
// RISING, db_size GAPPY (a nil sample dropped), disk FLAT (steady → mid-height),
// and webhooks ALL-NIL (every point a gap → an honest em-dash cell). The other
// meters are absent from the series (no history → em dash too).
const usageHistoryEnvelope = `{"ok":true,"series":{` +
	`"documents":[{"at":"2026-07-10T00:00:00Z","value":10},{"at":"2026-07-10T00:15:00Z","value":20},{"at":"2026-07-10T00:30:00Z","value":40},{"at":"2026-07-10T00:45:00Z","value":80}],` +
	`"db_size":[{"at":"2026-07-10T00:00:00Z","value":1048576},{"at":"2026-07-10T00:15:00Z","value":null},{"at":"2026-07-10T00:30:00Z","value":2097152}],` +
	`"disk":[{"at":"2026-07-10T00:00:00Z","value":42},{"at":"2026-07-10T00:15:00Z","value":42},{"at":"2026-07-10T00:30:00Z","value":42}],` +
	`"webhooks":[{"at":"2026-07-10T00:00:00Z","value":null},{"at":"2026-07-10T00:15:00Z","value":null}]}}`

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

// TestRunCloudUsageUsage: extra positionals and unknown flags are usage errors
// (exit 2). The no-arg form is NO LONGER a usage error — it is the fleet summary
// path, so with no login it falls through to the auth gate (exit auth), proving
// the dispatch branch splits on positional count.
func TestRunCloudUsageUsage(t *testing.T) {
	withTempConfigHome(t)
	// No-arg → fleet path → auth gate (not a usage error) when unauthenticated.
	if _, _, code := runUsage(t, "table", false); code != exitAuth {
		t.Fatalf("no-arg exit = %d, want %d (fleet path hits the auth gate)", code, exitAuth)
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

// usageQuotaEnvelope is a live box carrying plan limits: documents past its
// warn line (near_limit), datasets sitting EXACTLY on its ceiling (over_limit —
// the inclusive guard), webhooks well under both (a limit present but no state
// tripped → live), and instances (the 9th meter) live under its cap. The
// unmetered meters keep the honest dash.
const usageQuotaEnvelope = `{"usage":{"meters":{` +
	`"documents":{"value":850,"quota":1000,"warn_at":800,"source":"instance.documents","measured_at":null},` +
	`"datasets":{"value":50,"quota":50,"warn_at":40,"source":"instance.datasets","measured_at":null},` +
	`"webhooks":{"value":3,"quota":100,"warn_at":80,"source":"instance.webhooks.production","measured_at":null},` +
	`"db_size":{"value":"unmetered","quota":null,"warn_at":null,"source":"telemetry.pg_size_bytes","measured_at":null},` +
	`"disk":{"value":"unmetered","quota":null,"warn_at":null,"source":"telemetry.disk_used_percent","measured_at":null},` +
	`"seats":{"value":2,"quota":null,"warn_at":null,"source":"control-plane.team_members","measured_at":null,"pending_invitations":0},` +
	`"api_requests":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null},` +
	`"bandwidth":{"value":"unmetered","quota":null,"warn_at":null,"source":"not-metered","measured_at":null},` +
	`"instances":{"value":3,"quota":5,"warn_at":4,"source":"control-plane.team_instances","measured_at":null}}}}`

// TestUsageStateToken pins the pure quota-state logic: over_limit is inclusive at
// the ceiling (matching the create-time guard), near_limit fires at/above warn_at
// but under the ceiling, over_limit wins when a value is past BOTH lines, either
// limit works alone, and an unmetered/absent meter can never read as a quota
// state (no fake ceiling on a quiet pipe).
func TestUsageStateToken(t *testing.T) {
	cases := []struct {
		name    string
		present bool
		meter   cloudclient.UsageMeter
		want    string
	}{
		{"absent meter is unmetered", false, cloudclient.UsageMeter{Value: "unmetered"}, "unmetered"},
		{"unmetered sentinel is unmetered", true, cloudclient.UsageMeter{Value: "unmetered"}, "unmetered"},
		{"metered, no limit is live", true, cloudclient.UsageMeter{Value: 128.0}, "live"},
		{"metered under warn is live", true, cloudclient.UsageMeter{Value: 700.0, Quota: fp(1000), WarnAt: fp(800)}, "live"},
		{"metered at warn is near_limit", true, cloudclient.UsageMeter{Value: 800.0, Quota: fp(1000), WarnAt: fp(800)}, "near_limit"},
		{"metered above warn is near_limit", true, cloudclient.UsageMeter{Value: 950.0, Quota: fp(1000), WarnAt: fp(800)}, "near_limit"},
		{"metered AT quota is over_limit (inclusive)", true, cloudclient.UsageMeter{Value: 1000.0, Quota: fp(1000), WarnAt: fp(800)}, "over_limit"},
		{"metered above quota is over_limit", true, cloudclient.UsageMeter{Value: 1200.0, Quota: fp(1000), WarnAt: fp(800)}, "over_limit"},
		{"over_limit wins when past both lines", true, cloudclient.UsageMeter{Value: 1000.0, Quota: fp(1000), WarnAt: fp(500)}, "over_limit"},
		{"warn_at alone (no quota) → near_limit", true, cloudclient.UsageMeter{Value: 90.0, WarnAt: fp(80)}, "near_limit"},
		{"quota alone (no warn) at ceiling → over_limit", true, cloudclient.UsageMeter{Value: 100.0, Quota: fp(100)}, "over_limit"},
		// OC25 over_at — the red line fires with or without a quota, and BEFORE it.
		{"over_at crossed, no quota (a rate meter) → over_limit", true, cloudclient.UsageMeter{Value: 300.0, WarnAt: fp(210), OverAt: fp(270)}, "over_limit"},
		{"over_at crossed, BELOW the bar ceiling (cpu 95<100) → over_limit", true, cloudclient.UsageMeter{Value: 95.0, Quota: fp(100), WarnAt: fp(70), OverAt: fp(90)}, "over_limit"},
		{"between warn_at and over_at → near_limit", true, cloudclient.UsageMeter{Value: 80.0, Quota: fp(100), WarnAt: fp(70), OverAt: fp(90)}, "near_limit"},
		{"under warn_at with thresholds present → live", true, cloudclient.UsageMeter{Value: 40.0, WarnAt: fp(210), OverAt: fp(270)}, "live"},
		{"at over_at exactly (inclusive) → over_limit", true, cloudclient.UsageMeter{Value: 90.0, Quota: fp(100), WarnAt: fp(70), OverAt: fp(90)}, "over_limit"},
	}
	for _, c := range cases {
		if got := usageStateToken(c.meter, c.present); got != c.want {
			t.Errorf("%s: usageStateToken = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestRunCloudUsageQuotaStates renders an envelope carrying plan limits and
// proves the STATE cell is the quota-state token (near_limit/over_limit) with the
// "value / quota" fraction in LIMIT, that an at-ceiling meter reads over_limit,
// and that a limited-but-untripped meter stays "live".
func TestRunCloudUsageQuotaStates(t *testing.T) {
	newUsageServer(t, 200, usageQuotaEnvelope)
	stdout, _, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}

	docs := usageTestRow(t, stdout, "Documents")
	if !strings.Contains(docs, "near_limit") {
		t.Fatalf("documents past warn_at must read near_limit:\n%s", docs)
	}
	if !strings.Contains(docs, "850 / 1000") {
		t.Fatalf("documents LIMIT must show the value/quota fraction:\n%s", docs)
	}

	// datasets sits EXACTLY on its ceiling (50/50) → over_limit, not near_limit.
	sets := usageTestRow(t, stdout, "Datasets")
	if !strings.Contains(sets, "over_limit") {
		t.Fatalf("datasets at exactly quota must read over_limit:\n%s", sets)
	}
	if strings.Contains(sets, "near_limit") {
		t.Fatalf("an at-ceiling meter must NOT also read near_limit:\n%s", sets)
	}
	if !strings.Contains(sets, "50 / 50") {
		t.Fatalf("datasets LIMIT must show the value/quota fraction:\n%s", sets)
	}

	// webhooks carries a limit but is well under warn → plain live (no fake alarm).
	hooks := usageTestRow(t, stdout, "Webhooks")
	if !strings.Contains(hooks, "live") || strings.Contains(hooks, "limit") {
		t.Fatalf("a limited-but-untripped meter must stay live:\n%s", hooks)
	}

	// the 9th meter renders honestly (live, under its cap).
	if !strings.Contains(stdout, "Instances") {
		t.Fatalf("the instances meter row must render:\n%s", stdout)
	}
}

// TestRunCloudUsageQuotaStateColors proves the quota-state STATE cells paint
// through the shared statusRole seam: near_limit → warn/yellow, over_limit →
// danger/red — the same tones a dashboard meter draws.
func TestRunCloudUsageQuotaStateColors(t *testing.T) {
	newUsageServer(t, 200, usageQuotaEnvelope)
	colored, _, _ := runUsage(t, "table", true, testInstanceID)
	if !strings.Contains(colored, "\033[33m") {
		t.Fatalf("want a yellow (warn) near_limit STATE cell:\n%q", colored)
	}
	if !strings.Contains(colored, "\033[31m") {
		t.Fatalf("want a red (danger) over_limit STATE cell:\n%q", colored)
	}
}

// ---- fleet summary (`bp cloud usage`, no argument) ----

// fMeter builds an unmetered-or-metered meter object for a fake fleet payload:
// pass a number for a real reading or the "unmetered" sentinel for a quiet pipe.
func fMeter(value any, source string) map[string]any {
	return map[string]any{"value": value, "quota": nil, "warn_at": nil, "source": source, "measured_at": nil}
}

// fMeterQuota builds a metered meter carrying a plan limit (value/quota/warn_at).
func fMeterQuota(value, quota, warn float64, source string) map[string]any {
	return map[string]any{"value": value, "quota": quota, "warn_at": warn, "source": source, "measured_at": nil}
}

// buildFleetPayload assembles the OC16 fleet summary envelope from a team
// instances meter (or nil to omit it) and per-instance rows.
func buildFleetPayload(t *testing.T, team map[string]any, instances []map[string]any) string {
	t.Helper()
	teamBlock := map[string]any{}
	if team != nil {
		teamBlock["instances"] = team
	}
	if instances == nil {
		instances = []map[string]any{}
	}
	env := map[string]any{
		"usage": map[string]any{
			"team":      teamBlock,
			"instances": instances,
		},
	}
	b, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal fleet payload: %v", err)
	}
	return string(b)
}

// agoStamp is an RFC3339 timestamp d in the past, for deterministic relative-age
// assertions (kept at minute+ granularity so a few seconds of test drift can't
// flip the bucket).
func agoStamp(d time.Duration) *string {
	s := time.Now().Add(-d).UTC().Format(time.RFC3339)
	return &s
}

// freshFleetRow is a healthy, AGENT-ARMED sampled box: docs + telemetry + seats +
// the machine capacity beat (cpu/ram, well under their physical ceilings) all
// metered, sampled minutes ago.
func freshFleetRow() map[string]any {
	return map[string]any{
		"id": testInstanceID, "name": "alpha", "slug": "alpha", "host": "alpha.bp.dev",
		"measured_at": agoStamp(5 * time.Minute),
		"meters": map[string]any{
			"documents":    fMeter(128.0, "instance.documents"),
			"datasets":     fMeter(4.0, "instance.datasets"),
			"webhooks":     fMeter(3.0, "instance.webhooks.production"),
			"db_size":      fMeter(4194304.0, "telemetry.pg_size_bytes"),
			"disk":         fMeter(42.0, "telemetry.disk_used_percent"),
			"seats":        fMeter(2.0, "control-plane.team_members"),
			"cpu_pct":      fMeterQuota(23.0, 100.0, 70.0, "agent.cpu_percent"),
			"ram_pct":      fMeterQuota(58.0, 100.0, 70.0, "agent.ram_percent"),
			"api_requests": fMeter(unmeteredValue, "not-metered"),
			"bandwidth":    fMeter(unmeteredValue, "not-metered"),
			"instances":    fMeter(3.0, "control-plane.team_instances"),
		},
	}
}

// TestRunCloudFleetUsageDispatch: no positional hits GET /v1/usage/summary with
// the cloud bearer — the dispatch branch on positional count, no resolve call.
func TestRunCloudFleetUsageDispatch(t *testing.T) {
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{freshFleetRow()})
	method, path, auth := newUsageServer(t, 200, body)

	stdout, stderr, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "GET" || *path != "/v1/usage/summary" {
		t.Fatalf("hit %s %s, want GET /v1/usage/summary", *method, *path)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the cloud session bearer", *auth)
	}
}

// TestRunCloudFleetUsageFresh: a healthy sampled fleet renders the header count,
// the instance name, formatted headline values (human bytes, percent), a
// relative "as of" age, and a live STATE.
func TestRunCloudFleetUsageFresh(t *testing.T) {
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{freshFleetRow()})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, want := range []string{
		"Instances 3 of 5", // team header
		"alpha",            // instance name
		"128",              // docs
		"4.0 MB",           // db_size
		"42%",              // disk
		"23%",              // cpu capacity beat
		"58%",              // ram capacity beat
		"5m ago",           // relative sample age
		"live",             // healthy STATE — an armed box under its ceilings
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("fresh fleet render missing %q:\n%s", want, stdout)
		}
	}
	// The CPU · RAM headline columns render for an armed box.
	for _, col := range []string{"CPU", "RAM"} {
		if !strings.Contains(stdout, col) {
			t.Fatalf("fleet table must carry the %q headline column:\n%s", col, stdout)
		}
	}
}

// TestRunCloudFleetUsageStale: an hours-old sample renders its age as "Nh ago",
// never a fake-fresh reading.
func TestRunCloudFleetUsageStale(t *testing.T) {
	row := freshFleetRow()
	row["measured_at"] = agoStamp(3*time.Hour + 15*time.Minute)
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{row})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "3h ago") {
		t.Fatalf("a stale row must render its hours-old age:\n%s", stdout)
	}
}

// TestRunCloudFleetUsageNoSample: a never-sampled row (measured_at null, all
// headline meters unmetered) reads an honest "no sample yet" AS OF and an
// unmetered STATE — never a fake-fresh value, never a false "live" glow.
func TestRunCloudFleetUsageNoSample(t *testing.T) {
	row := map[string]any{
		"id": testInstanceID, "name": "beta", "slug": "beta", "host": "beta.bp.dev",
		"measured_at": nil,
		"meters": map[string]any{
			"documents":    fMeter(unmeteredValue, "instance.documents"),
			"datasets":     fMeter(unmeteredValue, "instance.datasets"),
			"webhooks":     fMeter(unmeteredValue, "instance.webhooks.production"),
			"db_size":      fMeter(unmeteredValue, "telemetry.pg_size_bytes"),
			"disk":         fMeter(unmeteredValue, "telemetry.disk_used_percent"),
			"seats":        fMeter(unmeteredValue, "control-plane.team_members"),
			"api_requests": fMeter(unmeteredValue, "not-metered"),
			"bandwidth":    fMeter(unmeteredValue, "not-metered"),
			"instances":    fMeter(unmeteredValue, "control-plane.team_instances"),
		},
	}
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{row})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	betaRow := usageTestRow(t, stdout, "beta")
	if !strings.Contains(betaRow, "no sample yet") {
		t.Fatalf("a never-sampled row must read 'no sample yet':\n%s", betaRow)
	}
	if strings.Contains(betaRow, "live") {
		t.Fatalf("a blind row must not read a false 'live':\n%s", betaRow)
	}
	if !strings.Contains(betaRow, "unmetered") {
		t.Fatalf("a fully-unmetered row's STATE must read unmetered:\n%s", betaRow)
	}
	// the headline value cells dash out honestly (no fake zero).
	if !strings.Contains(betaRow, "—") {
		t.Fatalf("an unmetered headline value must render an em dash:\n%s", betaRow)
	}
}

// TestRunCloudFleetUsageUnmetered: a partially-dark box (docs live, db_size
// unmetered) dashes the quiet cell and rolls the row STATE to unmetered — one
// dark source degrades the row's glance, never a fake-healthy green (D51).
func TestRunCloudFleetUsageUnmetered(t *testing.T) {
	row := freshFleetRow()
	row["name"] = "gamma"
	row["slug"] = "gamma"
	meters := row["meters"].(map[string]any)
	meters["db_size"] = fMeter(unmeteredValue, "telemetry.pg_size_bytes")
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{row})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	gammaRow := usageTestRow(t, stdout, "gamma")
	if !strings.Contains(gammaRow, "unmetered") {
		t.Fatalf("a row with a dark headline meter must roll STATE to unmetered:\n%s", gammaRow)
	}
	if !strings.Contains(gammaRow, "128") {
		t.Fatalf("the still-live docs value must render:\n%s", gammaRow)
	}
}

// TestRunCloudFleetUsageOverQuotaHeadline: a headline meter at/over its quota
// reddens the whole row (over_limit), and an over-quota team headline paints the
// instances line danger — the same warn/over story the dashboard tells.
func TestRunCloudFleetUsageOverQuotaHeadline(t *testing.T) {
	row := freshFleetRow()
	row["name"] = "delta"
	row["slug"] = "delta"
	meters := row["meters"].(map[string]any)
	meters["documents"] = fMeterQuota(1000, 1000, 800, "instance.documents") // exactly on the ceiling → over_limit
	// team at its instances ceiling → over_limit header.
	body := buildFleetPayload(t, fMeterQuota(5, 5, 4, "control-plane.team_instances"), []map[string]any{row})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "Instances 5 of 5") {
		t.Fatalf("an at-ceiling team must render its X of Y header:\n%s", stdout)
	}
	deltaRow := usageTestRow(t, stdout, "delta")
	if !strings.Contains(deltaRow, "over_limit") {
		t.Fatalf("a headline meter at its quota must roll STATE to over_limit:\n%s", deltaRow)
	}

	// with color on, the over_limit row + the over-quota header both paint danger red.
	newUsageServer(t, 200, body)
	colored, _, _ := runUsage(t, "table", true)
	if !strings.Contains(colored, "\033[31m") {
		t.Fatalf("an over_limit row/header must paint danger red:\n%q", colored)
	}
}

// TestRunCloudFleetUsageUnlimitedHeader: with no team quota the header is a plain
// "Instances N" — no "of Y" ceiling invented, no paint (D48 no-fake-ceiling).
func TestRunCloudFleetUsageUnlimitedHeader(t *testing.T) {
	body := buildFleetPayload(t, fMeter(3.0, "control-plane.team_instances"), []map[string]any{freshFleetRow()})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "Instances 3") {
		t.Fatalf("an unlimited team must render a plain count:\n%s", stdout)
	}
	if strings.Contains(stdout, "Instances 3 of") {
		t.Fatalf("an unlimited team must not invent a ceiling:\n%s", stdout)
	}
}

// TestRunCloudFleetUsageEmpty: an empty fleet is an honest empty state pointing
// at `bp cloud launch`, never a bare header with a skeletal table.
func TestRunCloudFleetUsageEmpty(t *testing.T) {
	body := buildFleetPayload(t, fMeter(0.0, "control-plane.team_instances"), []map[string]any{})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "table", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "No instances yet") {
		t.Fatalf("an empty fleet must render an honest empty state:\n%s", stdout)
	}
}

// TestRunCloudFleetUsageJSON: `-o json` emits the fleet envelope BYTES verbatim.
func TestRunCloudFleetUsageJSON(t *testing.T) {
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{freshFleetRow()})
	newUsageServer(t, 200, body)

	stdout, _, code := runUsage(t, "json", false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if stdout != body+"\n" {
		t.Fatalf("json output must be the fleet envelope verbatim:\n got: %q\nwant: %q", stdout, body+"\n")
	}
}

// TestRelativeAge pins the relative-age buckets directly (deterministic at
// minute+ granularity): minutes/hours/days ago, a future skew reading "just now",
// and an unparseable stamp falling back to its literal (never a crash).
func TestRelativeAge(t *testing.T) {
	now := time.Now()
	cases := []struct {
		name  string
		stamp string
		want  string
	}{
		{"minutes", now.Add(-5 * time.Minute).UTC().Format(time.RFC3339), "5m ago"},
		{"hours", now.Add(-3 * time.Hour).UTC().Format(time.RFC3339), "3h ago"},
		{"days", now.Add(-50 * time.Hour).UTC().Format(time.RFC3339), "2d ago"},
		{"future skew", now.Add(1 * time.Hour).UTC().Format(time.RFC3339), "just now"},
		{"unparseable falls back to literal", "not-a-timestamp", "not-a-timestamp"},
	}
	for _, c := range cases {
		if got := relativeAge(c.stamp); got != c.want {
			t.Errorf("%s: relativeAge(%q) = %q, want %q", c.name, c.stamp, got, c.want)
		}
	}
}

// TestFleetRowState pins the row STATE roll-up severity directly: over_limit
// outranks near_limit outranks unmetered outranks live; a partially-dark row is
// unmetered, a healthy row is live, and a tripped headline meter wins.
func TestFleetRowState(t *testing.T) {
	// A fully-armed, healthy box: every headline meter metered and under its
	// ceilings (the machine cpu/ram beat included) → live.
	live := map[string]cloudclient.UsageMeter{
		"documents": {Value: 10.0}, "db_size": {Value: 100.0}, "disk": {Value: 5.0}, "seats": {Value: 2.0},
		"cpu_pct": {Value: 20.0, Quota: fp(100), WarnAt: fp(70)}, "ram_pct": {Value: 35.0, Quota: fp(100), WarnAt: fp(70)},
	}
	if got := fleetRowState(live); got != "live" {
		t.Errorf("all-metered armed row = %q, want live", got)
	}
	// An un-armed box (no agent → cpu_pct/ram_pct absent) rolls to unmetered even
	// though its inventory meters are live — a box whose CAPACITY we can't see never
	// reads fully healthy (the same honesty a dark inventory pipe gets, D51).
	unarmed := map[string]cloudclient.UsageMeter{
		"documents": {Value: 10.0}, "db_size": {Value: 100.0}, "disk": {Value: 5.0}, "seats": {Value: 2.0},
	}
	if got := fleetRowState(unarmed); got != "unmetered" {
		t.Errorf("un-armed row (no cpu/ram) = %q, want unmetered", got)
	}
	dark := map[string]cloudclient.UsageMeter{
		"documents": {Value: 10.0}, "db_size": {Value: "unmetered"}, "disk": {Value: 5.0}, "seats": {Value: 2.0},
		"cpu_pct": {Value: 20.0, Quota: fp(100), WarnAt: fp(70)}, "ram_pct": {Value: 35.0, Quota: fp(100), WarnAt: fp(70)},
	}
	if got := fleetRowState(dark); got != "unmetered" {
		t.Errorf("partially-dark row = %q, want unmetered", got)
	}
	// A hot machine meter (RAM past its warn line) ambers the row — the capacity
	// beat contributes to the STATE fold exactly like an inventory quota.
	hot := map[string]cloudclient.UsageMeter{
		"documents": {Value: 10.0}, "db_size": {Value: 100.0}, "disk": {Value: 5.0}, "seats": {Value: 2.0},
		"cpu_pct": {Value: 20.0, Quota: fp(100), WarnAt: fp(70)}, "ram_pct": {Value: 88.0, Quota: fp(100), WarnAt: fp(70)},
	}
	if got := fleetRowState(hot); got != "near_limit" {
		t.Errorf("hot-RAM row = %q, want near_limit", got)
	}
	near := map[string]cloudclient.UsageMeter{
		"documents": {Value: 90.0, Quota: fp(100), WarnAt: fp(80)}, "db_size": {Value: "unmetered"},
		"disk": {Value: 5.0}, "seats": {Value: 2.0},
		"cpu_pct": {Value: 20.0, Quota: fp(100), WarnAt: fp(70)}, "ram_pct": {Value: 35.0, Quota: fp(100), WarnAt: fp(70)},
	}
	if got := fleetRowState(near); got != "near_limit" {
		t.Errorf("near-limit-with-dark row = %q, want near_limit (near outranks unmetered)", got)
	}
	over := map[string]cloudclient.UsageMeter{
		"documents": {Value: 100.0, Quota: fp(100), WarnAt: fp(80)}, "db_size": {Value: 90.0, Quota: fp(100), WarnAt: fp(80)},
		"disk": {Value: 5.0}, "seats": {Value: 2.0},
		"cpu_pct": {Value: 20.0, Quota: fp(100), WarnAt: fp(70)}, "ram_pct": {Value: 35.0, Quota: fp(100), WarnAt: fp(70)},
	}
	if got := fleetRowState(over); got != "over_limit" {
		t.Errorf("over-limit row = %q, want over_limit", got)
	}
}

// ---- TREND sparkline column (per-instance history, OC21) ----

// TestSparkRunes pins the eighth-block primitive directly: an ascending series
// walks the full ladder, endpoints land on ▁/█ regardless of scale, a flat or
// single-point series paints MID-height (▅, the deliberate divergence from
// pdrender's baseline floor), and an empty series is "" (the caller's em-dash
// signal).
func TestSparkRunes(t *testing.T) {
	if got := sparkRunes([]float64{1, 2, 3, 4, 5, 6, 7, 8}); got != "▁▂▃▄▅▆▇█" {
		t.Errorf("ascending ladder: got %q, want ▁▂▃▄▅▆▇█", got)
	}
	got := sparkRunes([]float64{100, 800})
	if r := []rune(got); string(r[0]) != "▁" || string(r[len(r)-1]) != "█" {
		t.Errorf("scaled endpoints: got %q, want first ▁ last █", got)
	}
	if got := sparkRunes([]float64{5, 5, 5}); got != "▅▅▅" {
		t.Errorf("flat series: got %q, want mid-height ▅▅▅", got)
	}
	if got := sparkRunes([]float64{9}); got != "▅" {
		t.Errorf("single point: got %q, want mid-height ▅", got)
	}
	if got := sparkRunes(nil); got != "" {
		t.Errorf("empty series: got %q, want empty string", got)
	}
}

// fp2 builds a *float64 for a history point value (a nil pointer is a gap).
func fp2(v float64) *float64 { return &v }

// TestUsageTrendCell pins the per-meter cell logic: a rising series draws its
// sparkline, a gappy series DROPS its nils (never a fake zero), a flat series is
// mid-height, an all-nil series is an em dash, and a meter absent from the history
// is an em dash.
func TestUsageTrendCell(t *testing.T) {
	history := map[string][]cloudclient.UsageHistoryPoint{
		"documents": {{Value: fp2(10)}, {Value: fp2(20)}, {Value: fp2(40)}, {Value: fp2(80)}},
		"db_size":   {{Value: fp2(1048576)}, {Value: nil}, {Value: fp2(2097152)}},
		"disk":      {{Value: fp2(42)}, {Value: fp2(42)}, {Value: fp2(42)}},
		"webhooks":  {{Value: nil}, {Value: nil}},
	}
	cases := []struct {
		name, want string
	}{
		{"documents", "▁▂▄█"}, // rising, own min..max
		{"db_size", "▁█"},     // the nil gap is dropped, two real points
		{"disk", "▅▅▅"},       // flat → mid-height
		{"webhooks", "—"},     // all-nil → honest em dash
		{"datasets", "—"},     // absent from history → em dash
	}
	for _, c := range cases {
		if got := usageTrendCell(c.name, history); got != c.want {
			t.Errorf("%s: usageTrendCell = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestHistoryHasData proves the column gate: a history with any numeric point is
// data (column shows); an empty map, a nil map, and an all-gaps history are NOT
// (column dropped, never a lonely run of em dashes).
func TestHistoryHasData(t *testing.T) {
	if !historyHasData(map[string][]cloudclient.UsageHistoryPoint{"documents": {{Value: fp2(1)}}}) {
		t.Errorf("a series with a real point must count as data")
	}
	if historyHasData(nil) {
		t.Errorf("a nil history must not count as data")
	}
	if historyHasData(map[string][]cloudclient.UsageHistoryPoint{}) {
		t.Errorf("an empty history must not count as data")
	}
	allGaps := map[string][]cloudclient.UsageHistoryPoint{"webhooks": {{Value: nil}, {Value: nil}}}
	if historyHasData(allGaps) {
		t.Errorf("an all-gaps history must not count as data")
	}
}

// TestRunCloudUsageTrendColumn: when the sampler's history is present the human
// table grows a TREND column painting each meter's sparkline — rising documents,
// a gap-dropped db_size, and a flat mid-height disk all render.
func TestRunCloudUsageTrendColumn(t *testing.T) {
	newUsageHistoryServer(t, usageMixedEnvelope, 200, usageHistoryEnvelope)

	stdout, _, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "TREND") {
		t.Fatalf("history present must add a TREND column header:\n%s", stdout)
	}
	if docs := usageTestRow(t, stdout, "Documents"); !strings.Contains(docs, "▁▂▄█") {
		t.Fatalf("documents TREND must draw the rising sparkline:\n%s", docs)
	}
	if db := usageTestRow(t, stdout, "DB size"); !strings.Contains(db, "▁█") {
		t.Fatalf("db_size TREND must drop the nil gap and draw two points:\n%s", db)
	}
	if disk := usageTestRow(t, stdout, "Disk"); !strings.Contains(disk, "▅▅▅") {
		t.Fatalf("disk TREND must draw a flat mid-height run:\n%s", disk)
	}
}

// TestRunCloudUsageTrendFailSoft: a history read that 404s (an older control
// plane without the route) or 500s degrades SILENTLY to the pre-existing table —
// no TREND column, exit 0, the meters still render.
func TestRunCloudUsageTrendFailSoft(t *testing.T) {
	for _, hs := range []int{404, 500} {
		newUsageHistoryServer(t, usageMixedEnvelope, hs, `{"error":"nope"}`)
		stdout, _, code := runUsage(t, "table", false, testInstanceID)
		if code != exitOK {
			t.Fatalf("history %d: exit = %d, want 0 (fail-soft)\n%s", hs, code, stdout)
		}
		if strings.Contains(stdout, "TREND") {
			t.Fatalf("history %d: a failed history read must drop the TREND column:\n%s", hs, stdout)
		}
		if !strings.Contains(stdout, "Documents") || !strings.Contains(stdout, "128") {
			t.Fatalf("history %d: the meters must still render on the fail-soft path:\n%s", hs, stdout)
		}
	}
}

// TestRunCloudUsageTrendEmptyHistory: a 200 history with NO numeric points (a box
// the sampler has stored only gaps for, or a just-deployed empty series) draws no
// TREND column — a lonely all-em-dash column is noise, not signal.
func TestRunCloudUsageTrendEmptyHistory(t *testing.T) {
	newUsageHistoryServer(t, usageMixedEnvelope, 200, `{"ok":true,"series":{}}`)
	stdout, _, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if strings.Contains(stdout, "TREND") {
		t.Fatalf("an empty history must not draw a TREND column:\n%s", stdout)
	}
}

// TestRunCloudUsageTrendRawNoFetch: the raw paths (-o json/-o yaml) emit the LIVE
// /usage envelope byte-unchanged and make NO history fetch — scripts depend on the
// exact shape, and the trend is a human garnish only.
func TestRunCloudUsageTrendRawNoFetch(t *testing.T) {
	// json is byte-verbatim AND never touches /usage/history.
	paths := newUsageHistoryServer(t, usageMixedEnvelope, 200, usageHistoryEnvelope)
	stdout, _, code := runUsage(t, "json", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if stdout != usageMixedEnvelope+"\n" {
		t.Fatalf("json must be the /usage envelope verbatim (no history):\n got: %q\nwant: %q", stdout, usageMixedEnvelope+"\n")
	}
	for _, p := range *paths {
		if strings.HasSuffix(p, "/usage/history") {
			t.Fatalf("the raw path must make NO history fetch, saw %q", p)
		}
	}

	// yaml likewise makes no history fetch.
	paths2 := newUsageHistoryServer(t, usageMixedEnvelope, 200, usageHistoryEnvelope)
	if _, _, code := runUsage(t, "yaml", false, testInstanceID); code != exitOK {
		t.Fatalf("yaml exit = %d, want 0", code)
	}
	for _, p := range *paths2 {
		if strings.HasSuffix(p, "/usage/history") {
			t.Fatalf("the yaml raw path must make NO history fetch, saw %q", p)
		}
	}
}

// TestRunCloudUsageTrendRawByteStable: the -o json bytes are IDENTICAL whether the
// history endpoint is present (200) or absent (404) — the trend never leaks into
// the machine contract.
func TestRunCloudUsageTrendRawByteStable(t *testing.T) {
	newUsageHistoryServer(t, usageMixedEnvelope, 200, usageHistoryEnvelope)
	withHist, _, _ := runUsage(t, "json", false, testInstanceID)

	newUsageHistoryServer(t, usageMixedEnvelope, 404, `{"error":"not_found"}`)
	withoutHist, _, _ := runUsage(t, "json", false, testInstanceID)

	if withHist != withoutHist {
		t.Fatalf("json bytes must be identical with/without history:\n present: %q\n absent:  %q", withHist, withoutHist)
	}
	if withHist != usageMixedEnvelope+"\n" {
		t.Fatalf("json must be the /usage envelope verbatim:\n got: %q", withHist)
	}
}

// TestRunCloudFleetUsageNoHistoryFetch: the fleet (no-arg) path reads ONLY
// /v1/usage/summary — it never probes /usage/history (the trend is a per-instance
// garnish, and the fleet view is byte-unchanged by this slice).
func TestRunCloudFleetUsageNoHistoryFetch(t *testing.T) {
	body := buildFleetPayload(t, fMeterQuota(3, 5, 4, "control-plane.team_instances"), []map[string]any{freshFleetRow()})
	paths := newUsageHistoryServer(t, body, 200, usageHistoryEnvelope)

	if _, _, code := runUsage(t, "table", false); code != exitOK {
		t.Fatalf("fleet exit != 0")
	}
	for _, p := range *paths {
		if strings.HasSuffix(p, "/usage/history") {
			t.Fatalf("the fleet path must make NO history fetch, saw %q", p)
		}
		if !strings.HasSuffix(p, "/usage/summary") {
			t.Fatalf("the fleet path must hit only /usage/summary, saw %q", p)
		}
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

// TestFormatMeterValueMachineMeters pins the machine-meter unit formats (OC26):
// cpu/ram/disk render as percents, req_per_s as a rate, p95_ms as a latency, and
// a plain count meter stays bare.
func TestFormatMeterValueMachineMeters(t *testing.T) {
	cases := []struct {
		name string
		n    float64
		want string
	}{
		{"cpu", 63, "63%"},
		{"ram", 71.5, "71.5%"},
		{"disk", 42, "42%"},
		{"req_per_s", 12.4, "12.4/s"},
		{"req_per_s", 200, "200/s"},
		{"p95_ms", 140, "140 ms"},
		{"documents", 812, "812"}, // a plain count is unchanged
	}
	for _, c := range cases {
		if got := formatMeterValue(c.name, c.n); got != c.want {
			t.Errorf("formatMeterValue(%q, %v) = %q, want %q", c.name, c.n, got, c.want)
		}
	}
}

// TestRunCloudUsageMachineMetersRender proves the four new meters render in the
// per-instance table with their units + OC25 quota states off a live envelope:
// cpu over (94 ≥ over_at 90) reads over_limit, ram near (76 ≥ warn 70) reads
// near_limit, req_per_s renders its rate unit, and an unreported p95_ms is the
// honest unmetered dash — never a fake zero.
func TestRunCloudUsageMachineMetersRender(t *testing.T) {
	newUsageServer(t, 200, usageMachineEnvelope)
	stdout, _, code := runUsage(t, "table", false, testInstanceID)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}

	cpu := usageTestRow(t, stdout, "CPU")
	if !strings.Contains(cpu, "94%") || !strings.Contains(cpu, "over_limit") {
		t.Fatalf("cpu at 94%% must read 94%% + over_limit:\n%s", cpu)
	}
	ram := usageTestRow(t, stdout, "RAM")
	if !strings.Contains(ram, "76%") || !strings.Contains(ram, "near_limit") {
		t.Fatalf("ram at 76%% must read 76%% + near_limit:\n%s", ram)
	}
	req := usageTestRow(t, stdout, "Req/s")
	if !strings.Contains(req, "250/s") || !strings.Contains(req, "near_limit") {
		t.Fatalf("req_per_s at 250 must read 250/s + near_limit:\n%s", req)
	}
	p95 := usageTestRow(t, stdout, "p95 latency")
	if !strings.Contains(p95, "unmetered") {
		t.Fatalf("an unreported p95 latency must stay unmetered, never a fake zero:\n%s", p95)
	}
}

// usageMachineEnvelope is a live box reporting the machine meters (OC26): cpu OVER
// its red line (94 ≥ over_at 90, still below the 100 bar ceiling), ram in the warn
// band (76 ≥ warn 70), req_per_s near its rate warn line (250 ≥ 210, no quota),
// and p95_ms not yet reported by the instance runtime (honest unmetered). The
// legacy meters ride along unmetered so the row set stays whole.
const usageMachineEnvelope = `{"usage":{"meters":{` +
	`"documents":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.documents","measured_at":null},` +
	`"datasets":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.datasets","measured_at":null},` +
	`"webhooks":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"instance.webhooks","measured_at":null},` +
	`"db_size":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"telemetry.pg_size_bytes","measured_at":null},` +
	`"disk":{"value":42,"quota":100,"warn_at":70,"over_at":90,"source":"telemetry.disk_used_percent","measured_at":"2026-07-10T04:00:00Z"},` +
	`"cpu":{"value":94,"quota":100,"warn_at":70,"over_at":90,"source":"telemetry.cpu_percent","measured_at":"2026-07-10T04:00:00Z"},` +
	`"ram":{"value":76,"quota":100,"warn_at":70,"over_at":90,"source":"telemetry.mem_used_percent","measured_at":"2026-07-10T04:00:00Z"},` +
	`"req_per_s":{"value":250,"quota":null,"warn_at":210,"over_at":270,"source":"telemetry.req_per_s","measured_at":"2026-07-10T04:00:00Z"},` +
	`"p95_ms":{"value":"unmetered","quota":null,"warn_at":500,"over_at":1000,"source":"telemetry.p95_ms","measured_at":null},` +
	`"seats":{"value":2,"quota":null,"warn_at":null,"over_at":null,"source":"control-plane.team_members","measured_at":null,"pending_invitations":0},` +
	`"api_requests":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"not-metered","measured_at":null},` +
	`"bandwidth":{"value":"unmetered","quota":null,"warn_at":null,"over_at":null,"source":"not-metered","measured_at":null},` +
	`"instances":{"value":3,"quota":null,"warn_at":null,"over_at":null,"source":"control-plane.team_instances","measured_at":null}}}}`
