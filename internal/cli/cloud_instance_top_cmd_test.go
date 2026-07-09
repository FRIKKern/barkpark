package cli

// cloud_instance_top_cmd_test.go proves `bp cloud instance top` against a fake
// control plane: the vitals snapshot renders honestly for every beat state
// (live / stale / absent), `-o json` is the envelope BYTES verbatim (the CLI
// never becomes a second definition of the contract), the metricsBlocks Attrs
// adapter drops null samples as GAPS (never a fabricated zero), and the command
// is ONE-SHOT (no --watch). Zero live calls — the CLI is a pure consumer.

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// Committed envelope shapes mirroring the S12a control-plane serialization. Note
// the cpu series carries a NULL sample (a dropped beat) — a gap, never a zero.
const metricsLiveEnvelope = `{"ok":true,"collected_at":"2026-07-09T12:00:00Z","instance":{"id":"11111111-2222-3333-4444-555555555555","host":"prod.barkpark.cloud","provider":"hetzner"},"beat":{"last_seen_at":"2026-07-09T11:59:30Z","age_seconds":30,"status":"live"},"points":4,"series":{"cpu":[{"at":"t0","value":12},{"at":"t1","value":44},{"at":"t2","value":null},{"at":"t3","value":55}],"mem":[{"at":"t0","value":60},{"at":"t1","value":62},{"at":"t2","value":61},{"at":"t3","value":63}],"disk":[{"at":"t0","value":40},{"at":"t1","value":40},{"at":"t2","value":41},{"at":"t3","value":41}],"load":[{"at":"t0","value":0.5},{"at":"t1","value":1.2},{"at":"t2","value":0.8},{"at":"t3","value":1.1}]},"service_health":{"pass":3,"total":3,"failing":[]}}`

const metricsAbsentEnvelope = `{"ok":false,"collected_at":"2026-07-09T12:00:00Z","instance":{"id":"11111111-2222-3333-4444-555555555555","host":"new.barkpark.cloud","provider":"azure"},"beat":{"last_seen_at":"","age_seconds":0,"status":"absent"},"points":0,"series":{},"service_health":{"pass":0,"total":0,"failing":[]}}`

const metricsStaleEnvelope = `{"ok":false,"collected_at":"2026-07-09T12:00:00Z","instance":{"id":"11111111-2222-3333-4444-555555555555","host":"prod.barkpark.cloud","provider":"hetzner"},"beat":{"last_seen_at":"2026-07-09T11:57:00Z","age_seconds":180,"status":"stale"},"points":4,"series":{"cpu":[{"at":"t0","value":12},{"at":"t1","value":44},{"at":"t2","value":30},{"at":"t3","value":55}]},"service_health":{"pass":2,"total":3,"failing":["disk"]}}`

// newMetricsServer stands up a fake control plane answering the metrics route,
// seeds a cloud login pointed at it, and records the method + full request URI +
// auth header it saw.
func newMetricsServer(t *testing.T, status int, body string) (gotMethod, gotURI, gotAuth *string) {
	t.Helper()
	var m, u, a string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m, u, a = r.Method, r.URL.RequestURI(), r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	withTempConfigHome(t)
	seedCloudLogin(t, srv.URL)
	return &m, &u, &a
}

// runTop drives runCloudInstance with a "top" prefix (proving the dispatch wire)
// against an in-memory writer. A *bytes.Buffer stdout is non-tty, so the render
// is deterministic plain text at width 80.
func runTop(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	code := runCloudInstance(w, globals{}, append([]string{"top"}, args...))
	return sout.String(), serr.String(), code
}

// TestCloudInstanceTopTable: a live box renders the header, the beat line with
// the server-computed age, the stat values, and the health rollup — and the
// request is a Bearer-authed GET to the metrics route (a UUID needs no fleet
// resolve).
func TestCloudInstanceTopTable(t *testing.T) {
	method, uri, auth := newMetricsServer(t, 200, metricsLiveEnvelope)

	stdout, stderr, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	if *method != "GET" || *uri != "/v1/barkparks/"+testInstanceID+"/metrics" {
		t.Fatalf("hit %s %s, want GET /v1/barkparks/%s/metrics", *method, *uri, testInstanceID)
	}
	if *auth != "Bearer sess-abc" {
		t.Fatalf("auth=%q want the cloud session bearer", *auth)
	}
	for _, want := range []string{
		"Vitals for", "prod.barkpark.cloud", "hetzner",
		"beat: live", "last seen 30s ago",
		"CPU", "55%", "Memory", "63%", "Disk", "41%", "Load", "1.1",
		"service health: 3/3 passing",
	} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("table output missing %q:\n%s", want, stdout)
		}
	}
}

// TestCloudInstanceTopPointsQuery: --points rides through as the query param.
func TestCloudInstanceTopPointsQuery(t *testing.T) {
	_, uri, _ := newMetricsServer(t, 200, metricsLiveEnvelope)
	if _, stderr, code := runTop(t, "table", testInstanceID, "--points", "30"); code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if *uri != "/v1/barkparks/"+testInstanceID+"/metrics?points=30" {
		t.Fatalf("uri=%q want ?points=30", *uri)
	}
}

// TestCloudInstanceTopJSONVerbatim: -o json is the CP bytes verbatim — the CLI
// never reshapes the vitals contract.
func TestCloudInstanceTopJSONVerbatim(t *testing.T) {
	newMetricsServer(t, 200, metricsLiveEnvelope)
	stdout, stderr, code := runTop(t, "json", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if got := strings.TrimRight(stdout, "\n"); got != metricsLiveEnvelope {
		t.Fatalf("json not verbatim:\n got: %s\nwant: %s", got, metricsLiveEnvelope)
	}
}

// TestCloudInstanceTopAbsent: an absent beat is the honest "no vitals yet" state
// — NEVER a zeroed chart.
func TestCloudInstanceTopAbsent(t *testing.T) {
	newMetricsServer(t, 200, metricsAbsentEnvelope)
	stdout, _, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d", code)
	}
	if !strings.Contains(stdout, "beat: none yet") || !strings.Contains(stdout, "No vitals yet") {
		t.Fatalf("absent state not honest:\n%s", stdout)
	}
	if strings.Contains(stdout, "%") { // no percent stat cell → no chart was drawn
		t.Fatalf("absent state must not draw a chart:\n%s", stdout)
	}
}

// TestCloudInstanceTopStale: a quiet agent shows the last-known window with a
// STALE banner + the server age, and the grid still renders.
func TestCloudInstanceTopStale(t *testing.T) {
	newMetricsServer(t, 200, metricsStaleEnvelope)
	stdout, _, code := runTop(t, "table", testInstanceID)
	if code != exitOK {
		t.Fatalf("exit=%d", code)
	}
	for _, want := range []string{"STALE", "last seen 3m ago", "CPU", "55%", "service health: 2/3 passing", "failing: disk"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stale output missing %q:\n%s", want, stdout)
		}
	}
}

// TestCloudInstanceTopNoWatch: the command is ONE-SHOT — --watch is not a flag.
func TestCloudInstanceTopNoWatch(t *testing.T) {
	newMetricsServer(t, 200, metricsLiveEnvelope)
	_, stderr, code := runTop(t, "table", testInstanceID, "--watch")
	if code != exitUsage {
		t.Fatalf("exit=%d want usage (no --watch)", code)
	}
	if !strings.Contains(stderr, "unknown flag") {
		t.Fatalf("want unknown-flag error, got: %s", stderr)
	}
}

// TestCloudInstanceTopAuth: no login → an auth error before any network call.
func TestCloudInstanceTopAuth(t *testing.T) {
	withTempConfigHome(t) // config home with no cloud token
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	code := runCloudInstance(w, globals{}, []string{"top", testInstanceID})
	if code != exitAuth {
		t.Fatalf("exit=%d want auth", code)
	}
	if !strings.Contains(serr.String(), "not logged in") {
		t.Fatalf("want login hint, got: %s", serr.String())
	}
}

// fp returns a *float64 for envelope construction.
func fp(f float64) *float64 { return &f }

// TestMetricsBlocksAdapter: the Attrs adapter maps the envelope onto a stat-grid
// + chart, drops NULL samples as gaps (never a zero), renders a holes-only metric
// as an honest em-dash with no chart series, and picks the latest non-null value.
func TestMetricsBlocksAdapter(t *testing.T) {
	var res cloudclient.MetricsResult
	res.Series = map[string][]cloudclient.MetricPoint{
		"cpu":  {{At: "t0", Value: fp(10)}, {At: "t1", Value: nil}, {At: "t2", Value: fp(20)}},
		"mem":  {{Value: fp(60)}, {Value: fp(62)}},
		"disk": {{Value: nil}, {Value: nil}}, // holes-only
		"load": {{Value: fp(1.234)}},
	}
	blocks := metricsBlocks(res)
	if len(blocks) != 2 {
		t.Fatalf("want stat-grid + chart, got %d blocks", len(blocks))
	}
	if blocks[0].Type != "stat-grid" || blocks[1].Type != "chart" {
		t.Fatalf("block types = %q,%q want stat-grid,chart", blocks[0].Type, blocks[1].Type)
	}

	items, _ := blocks[0].Attrs["items"].([]any)
	if len(items) != len(metricTopSpecs) {
		t.Fatalf("stat-grid items=%d want %d", len(items), len(metricTopSpecs))
	}
	cpu := items[0].(map[string]any) // spec order: cpu first
	if cpu["value"] != "20%" {       // latest NON-NULL, not the null at t1
		t.Fatalf("cpu value=%v want 20%%", cpu["value"])
	}
	if spark, _ := cpu["spark"].([]any); len(spark) != 2 { // the null is dropped → 2 real samples
		t.Fatalf("cpu spark=%v want 2 (null dropped as a gap)", cpu["spark"])
	}
	disk := items[2].(map[string]any) // spec order: disk third
	if disk["value"] != "—" {
		t.Fatalf("holes-only disk value=%v want em-dash", disk["value"])
	}
	if _, hasSpark := disk["spark"]; hasSpark {
		t.Fatalf("holes-only disk must carry no spark")
	}
	load := items[3].(map[string]any)
	if load["value"] != "1.23" { // rounded, no unit
		t.Fatalf("load value=%v want 1.23", load["value"])
	}

	series, _ := blocks[1].Attrs["series"].([]any)
	if len(series) != 3 { // cpu, mem, load — the holes-only disk contributes none
		t.Fatalf("chart series=%d want 3 (holes-only disk excluded)", len(series))
	}
}

// TestMetricsBlocksAllHoles: a window with no numeric samples anywhere yields no
// blocks (the caller prints an honest line instead of an empty chart).
func TestMetricsBlocksAllHoles(t *testing.T) {
	var res cloudclient.MetricsResult
	res.Series = map[string][]cloudclient.MetricPoint{"cpu": {{Value: nil}}, "mem": {{Value: nil}}}
	if b := metricsBlocks(res); b != nil {
		t.Fatalf("all-holes window must yield nil blocks, got %d", len(b))
	}
}

// TestMetricsAgeText: honest human ages; a non-positive/garbage age → "".
func TestMetricsAgeText(t *testing.T) {
	cases := map[float64]string{0: "", -5: "", 30: "30s", 90: "1m", 3600: "1h", 90000: "1d"}
	for age, want := range cases {
		if got := metricsAgeText(age); got != want {
			t.Fatalf("metricsAgeText(%v)=%q want %q", age, got, want)
		}
	}
}

// TestMetricsHealthLine: absent counts hide (never "0/0"); failing checks surface.
func TestMetricsHealthLine(t *testing.T) {
	if got := metricsHealthLine(cloudclient.ServiceHealth{Total: 0}); strings.Contains(got, "0/0") {
		t.Fatalf("absent counts must not render 0/0, got %q", got)
	}
	ok := metricsHealthLine(cloudclient.ServiceHealth{Pass: 3, Total: 3})
	if !strings.Contains(ok, "3/3 passing") {
		t.Fatalf("want 3/3 passing, got %q", ok)
	}
	bad := metricsHealthLine(cloudclient.ServiceHealth{Pass: 1, Total: 3, Failing: []string{"disk", "http"}})
	if !strings.Contains(bad, "1/3 passing") || !strings.Contains(bad, "failing: disk, http") {
		t.Fatalf("want failing list, got %q", bad)
	}
}
