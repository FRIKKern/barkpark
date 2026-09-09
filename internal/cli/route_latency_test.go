package cli

import (
	"bytes"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// realShapeExposition is a Prometheus exposition in the shape the box ACTUALLY
// serves: the real bucket ladder from api/lib/barkpark_web/telemetry.ex
// (`latency_buckets` = 10,25,50,100,250,500,1000,2500,5000 + the terminal
// +Inf), the real family name, unrelated series interleaved, and the four
// routes measured on guerrilla on 2026-08-07 — /v1/graph never faster than
// 2.5 s, /v1/tasks/prime with 0 of 151 under 500 ms, data/search at ~3 s, and
// /v1/admin/site-deploy, the 448-hit trigger fan-out, which is 44 ms and is not
// a latency problem at all. That last route is the reason this fixture exists:
// it is the BUSIEST route on the box, so a reader that ranks by volume, or a
// box-level scalar, points at it and is wrong.
const realShapeExposition = `# HELP vm_memory_total Total BEAM memory
# TYPE vm_memory_total gauge
vm_memory_total 284512
# HELP barkpark_repo_query_total_time End-to-end Ecto query latency
# TYPE barkpark_repo_query_total_time histogram
barkpark_repo_query_total_time_bucket{le="10"} 918
barkpark_repo_query_total_time_bucket{le="+Inf"} 1204
# HELP phoenix_router_dispatch_stop_duration Per-route dispatch latency
# TYPE phoenix_router_dispatch_stop_duration histogram
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="10"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="25"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="50"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="100"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="250"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="500"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="1000"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="2500"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="5000"} 18
phoenix_router_dispatch_stop_duration_bucket{route="/v1/graph",le="+Inf"} 31
phoenix_router_dispatch_stop_duration_sum{route="/v1/graph"} 150257
phoenix_router_dispatch_stop_duration_count{route="/v1/graph"} 31
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="10"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="25"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="50"} 1
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="100"} 3
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="250"} 7
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="500"} 14
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="1000"} 30
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="2500"} 58
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="5000"} 88
phoenix_router_dispatch_stop_duration_bucket{route="/v1/data/:dataset/search",le="+Inf"} 90
phoenix_router_dispatch_stop_duration_sum{route="/v1/data/:dataset/search"} 269010
phoenix_router_dispatch_stop_duration_count{route="/v1/data/:dataset/search"} 90
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="10"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="25"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="50"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="100"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="250"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="500"} 0
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="1000"} 46
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="2500"} 141
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="5000"} 151
phoenix_router_dispatch_stop_duration_bucket{route="/v1/tasks/prime",le="+Inf"} 151
phoenix_router_dispatch_stop_duration_sum{route="/v1/tasks/prime"} 237674
phoenix_router_dispatch_stop_duration_count{route="/v1/tasks/prime"} 151
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="10"} 12
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="25"} 141
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="50"} 402
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="100"} 446
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="250"} 448
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="500"} 448
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="1000"} 448
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="2500"} 448
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="5000"} 448
phoenix_router_dispatch_stop_duration_bucket{route="/v1/admin/site-deploy",le="+Inf"} 448
phoenix_router_dispatch_stop_duration_sum{route="/v1/admin/site-deploy"} 19712
phoenix_router_dispatch_stop_duration_count{route="/v1/admin/site-deploy"} 448
# TYPE vm_total_run_queue_lengths_total gauge
vm_total_run_queue_lengths_total 0
`

// routeLatencyFixture stands up a fake box: a public /status.json reporting the
// given uptime and a Bearer-gated /v1/instance/metrics serving the exposition.
// It counts metrics hits so a test can prove the refusal path never scraped.
func routeLatencyFixture(t *testing.T, uptimeSeconds any, exposition string) (base string, metricsHits *int32) {
	t.Helper()
	var hits int32
	mux := http.NewServeMux()
	mux.HandleFunc("/status.json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		switch v := uptimeSeconds.(type) {
		case nil:
			fmt.Fprint(w, `{"status":"operational","commit":"654da8d2"}`)
		default:
			fmt.Fprintf(w, `{"status":"operational","commit":"654da8d2","uptime_seconds":%v}`, v)
		}
	})
	mux.HandleFunc("/v1/instance/metrics", func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		if r.Header.Get("Authorization") != "Bearer tok-abc" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Header().Set("content-type", "text/plain")
		fmt.Fprint(w, exposition)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv.URL, &hits
}

func runLatency(t *testing.T, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"
	code = runRouteLatency(w, args)
	return code, so.String(), se.String()
}

// TestRouteLatencyNamesTheSlowRoute is criterion 0: the consumer must say WHICH
// route is slow. The box-level p95_ms scalar this replaces structurally cannot.
//
// The trap is deliberate: /v1/admin/site-deploy is the BUSIEST route in the
// fixture (448 of 720 dispatches, 62%) and the FASTEST (p95 in the 25-50 ms
// bucket). A reader that ranks by volume, or that reports one box-level number,
// blames it. The verdict must name /v1/graph.
func TestRouteLatencyNamesTheSlowRoute(t *testing.T) {
	base, hits := routeLatencyFixture(t, 14400, realShapeExposition)

	code, stdout, stderr := runLatency(t, "--url", base, "--token", "tok-abc")
	t.Logf("rendered output:\n%s", stdout)

	if code != exitOK {
		t.Fatalf("exit = %d (want %d); stderr:\n%s", code, exitOK, stderr)
	}
	if got := atomic.LoadInt32(hits); got != 1 {
		t.Fatalf("metrics endpoint hit %d times, want exactly 1 — the reader is not reading the histogram", got)
	}
	if !strings.Contains(stdout, "=> SLOWEST: /v1/graph") {
		t.Errorf("the verdict does not NAME the slow route:\n%s", stdout)
	}
	if strings.Contains(stdout, "=> SLOWEST: /v1/admin/site-deploy") {
		t.Errorf("ranked the busiest route as the slowest — volume is not latency:\n%s", stdout)
	}
	// Every route in the fixture must appear, so the reader is a per-route
	// consumer and not a one-number one.
	for _, route := range []string{"/v1/graph", "/v1/data/:dataset/search", "/v1/tasks/prime", "/v1/admin/site-deploy"} {
		if !strings.Contains(stdout, route) {
			t.Errorf("route %q missing from the rendered table:\n%s", route, stdout)
		}
	}
	// Rank order: /v1/graph (p95 unbounded) before the two multi-second routes,
	// and site-deploy last.
	iGraph := strings.Index(stdout, "  /v1/graph")
	iPrime := strings.Index(stdout, "  /v1/tasks/prime")
	iDeploy := strings.Index(stdout, "  /v1/admin/site-deploy")
	if !(iGraph > 0 && iGraph < iPrime && iPrime < iDeploy) {
		t.Errorf("routes are not ranked worst-first (graph=%d prime=%d deploy=%d):\n%s",
			iGraph, iPrime, iDeploy, stdout)
	}
	// An unbounded p95 is rendered as a strict lower bound, never a fabricated
	// number: /v1/graph's 95th percentile is in the +Inf bucket.
	if !strings.Contains(stdout, "> 5000 ms") {
		t.Errorf("an unbounded p95 must render as a lower bound, not a number:\n%s", stdout)
	}
}

// TestRouteLatencyStatesItsWindow is the first half of criterion 1: every
// successful read names the window it is quoting.
func TestRouteLatencyStatesItsWindow(t *testing.T) {
	base, _ := routeLatencyFixture(t, 14400, realShapeExposition)
	code, stdout, _ := runLatency(t, "--url", base, "--token", "tok-abc")
	if code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(stdout, "cumulative since slot boot") {
		t.Errorf("output never states its window:\n%s", stdout)
	}
	if !strings.Contains(stdout, "4h 00m 00s of uptime") {
		t.Errorf("output does not quantify the window it read (want 4h 00m 00s):\n%s", stdout)
	}
}

// TestRouteLatencyRefusesOnFreshSlot is the second half of criterion 1, over a
// FRESH-SLOT fixture.
//
// The precondition is asserted, not assumed: the fixture's own /status.json is
// read back and its uptime PRINTED, so a green here cannot be a green over a
// mature slot that happened to fail for another reason. Both controls follow —
// the refusal fires, and no latency figure reaches stdout.
func TestRouteLatencyRefusesOnFreshSlot(t *testing.T) {
	base, hits := routeLatencyFixture(t, 42, realShapeExposition)

	// PRECONDITION: the fixture really is a fresh slot.
	win, err := fetchRouteLatencyWindow(base)
	if err != nil {
		t.Fatalf("fixture status.json unreadable: %v", err)
	}
	if !win.Known {
		t.Fatalf("fixture did not report uptime_seconds — it is not a fresh-slot fixture, it is an unknown-window one")
	}
	t.Logf("FIXTURE PRECONDITION: observed uptime_seconds = %v (%s), threshold = %ds",
		win.UptimeSeconds, humanDuration(win.UptimeSeconds), routeLatencyMinUptimeDefault)
	if win.UptimeSeconds >= routeLatencyMinUptimeDefault {
		t.Fatalf("fixture uptime %v is NOT below the %ds threshold — this test would prove nothing",
			win.UptimeSeconds, routeLatencyMinUptimeDefault)
	}

	code, stdout, stderr := runLatency(t, "--url", base, "--token", "tok-abc")
	all := stdout + stderr
	t.Logf("refusal output:\n%s", all)

	if code == exitOK {
		t.Fatalf("a fresh slot must not exit 0:\n%s", all)
	}
	if !strings.Contains(all, "REFUSED (slot_too_young)") {
		t.Errorf("the refusal is not named:\n%s", all)
	}
	if !strings.Contains(all, "cumulative since slot boot") {
		t.Errorf("the refusal does not state the window:\n%s", all)
	}
	if !strings.Contains(all, "42s") {
		t.Errorf("the refusal does not report the observed uptime:\n%s", all)
	}
	// It must REFUSE, not print. No route is named and no latency figure is
	// quoted — and the histogram is not even scraped.
	for _, leak := range []string{"SLOWEST", "/v1/graph", "p95", "> 5000 ms"} {
		if strings.Contains(all, leak) {
			t.Errorf("a refusal leaked %q — it printed a number instead of refusing:\n%s", leak, all)
		}
	}
	if got := atomic.LoadInt32(hits); got != 0 {
		t.Errorf("the refusal scraped the histogram %d time(s); it must refuse before reading", got)
	}
}

// TestRouteLatencyPrintsOnMatureSlotControl is the CONTROL for the refusal: the
// same fixture, the same command, one field different. Without it, a refusal
// that fires unconditionally would pass the test above.
func TestRouteLatencyPrintsOnMatureSlotControl(t *testing.T) {
	base, hits := routeLatencyFixture(t, routeLatencyMinUptimeDefault+1, realShapeExposition)
	code, stdout, stderr := runLatency(t, "--url", base, "--token", "tok-abc")
	if code != exitOK {
		t.Fatalf("a slot one second past the threshold must read: exit=%d\n%s%s", code, stdout, stderr)
	}
	if strings.Contains(stdout+stderr, "REFUSED") {
		t.Fatalf("the refusal fires unconditionally — it is not measuring slot age:\n%s", stdout)
	}
	if atomic.LoadInt32(hits) != 1 {
		t.Fatalf("the mature-slot path did not scrape the histogram")
	}
}

// TestRouteLatencyRefusesWhenWindowUnknown: a box that does not report
// uptime_seconds cannot qualify the window, so no figure is printed. This is
// the same discipline that makes p95_ms untrustworthy — a number over an
// unstated window — applied to this reader's own output.
func TestRouteLatencyRefusesWhenWindowUnknown(t *testing.T) {
	base, hits := routeLatencyFixture(t, nil, realShapeExposition)
	code, stdout, stderr := runLatency(t, "--url", base, "--token", "tok-abc")
	all := stdout + stderr
	if code == exitOK {
		t.Fatalf("an unknown window must not exit 0:\n%s", all)
	}
	if !strings.Contains(all, "REFUSED (unknown_window)") {
		t.Errorf("wrong refusal code:\n%s", all)
	}
	if strings.Contains(all, "SLOWEST") || atomic.LoadInt32(hits) != 0 {
		t.Errorf("printed or scraped despite an unknown window:\n%s", all)
	}
}

// TestRouteLatencyRefusesWhenHistogramIsEmpty: the family is exposed but nothing
// was dispatched. Zero samples is not "0 ms".
func TestRouteLatencyRefusesWhenHistogramIsEmpty(t *testing.T) {
	base, _ := routeLatencyFixture(t, 14400, "# TYPE vm_memory_total gauge\nvm_memory_total 1\n")
	code, stdout, stderr := runLatency(t, "--url", base, "--token", "tok-abc")
	all := stdout + stderr
	if code == exitOK {
		t.Fatalf("no samples must not exit 0:\n%s", all)
	}
	if !strings.Contains(all, "REFUSED (no_samples)") {
		t.Errorf("wrong refusal code:\n%s", all)
	}
}

// TestRouteLatencyQuantileMath pins the fold itself: the bracket is kept, an
// unbounded quantile stays unbounded, and the mean of a never-hit route is NaN
// rather than a fabricated zero.
func TestRouteLatencyQuantileMath(t *testing.T) {
	routes := parseRouteLatency(realShapeExposition)
	if len(routes) != 4 {
		t.Fatalf("parsed %d routes, want 4 — the parser is not reading the fixture", len(routes))
	}
	by := map[string]routeLatency{}
	for _, r := range routes {
		by[r.Route] = r
	}

	graph := by["/v1/graph"]
	if graph.Count != 31 {
		t.Errorf("/v1/graph count = %v, want 31", graph.Count)
	}
	q := graph.quantile(0.95)
	if q.Bounded {
		t.Errorf("/v1/graph p95 must be UNBOUNDED (rank 29.45 of 31 lands in the +Inf bucket after le=5000 holds 18), got %+v", q)
	}
	if q.Lower != 5000 {
		t.Errorf("/v1/graph p95 lower bound = %v, want 5000", q.Lower)
	}
	if !math.IsNaN(q.MS) {
		t.Errorf("an unbounded quantile must not carry a number, got %v", q.MS)
	}
	if mean := graph.MeanMS(); math.Abs(mean-4847) > 1 {
		t.Errorf("/v1/graph mean = %v, want ~4847", mean)
	}

	deploy := by["/v1/admin/site-deploy"]
	dq := deploy.quantile(0.95)
	if !dq.Bounded {
		t.Fatalf("/v1/admin/site-deploy p95 must be bounded, got %+v", dq)
	}
	// rank = 0.95*448 = 425.6, which falls in the (25, 50] bucket (141 → 402).
	if dq.Lower != 25 || dq.Upper != 50 {
		t.Errorf("/v1/admin/site-deploy p95 bracket = %v–%v, want 25–50", dq.Lower, dq.Upper)
	}
	if dq.MS < 25 || dq.MS > 50 {
		t.Errorf("interpolated p95 %v is outside its own bracket", dq.MS)
	}

	empty := routeLatency{Route: "/never"}
	if !math.IsNaN(empty.MeanMS()) {
		t.Errorf("a route with no observations must be NaN, not %v — zero samples is not 0 ms", empty.MeanMS())
	}
	if empty.quantile(0.95).Known {
		t.Errorf("a route with no observations must have no quantile")
	}
}

// TestRouteLatencyPromParser pins the label reader against exposition shapes the
// naive `strings.Split(",")` approach gets wrong.
func TestRouteLatencyPromParser(t *testing.T) {
	name, labels, value, ok := parsePromSample(`phoenix_router_dispatch_stop_duration_bucket{route="/w/:ws,x",le="+Inf"} 7`)
	if !ok {
		t.Fatal("well-formed sample rejected")
	}
	if name != "phoenix_router_dispatch_stop_duration_bucket" {
		t.Errorf("name = %q", name)
	}
	if labels["route"] != "/w/:ws,x" {
		t.Errorf("a comma inside a quoted label value truncated it: %q", labels["route"])
	}
	if labels["le"] != "+Inf" {
		t.Errorf("le = %q", labels["le"])
	}
	if value != 7 {
		t.Errorf("value = %v", value)
	}
	if _, _, _, ok := parsePromSample("# HELP something"); ok {
		t.Error("a comment must not parse as a sample")
	}
	if _, _, _, ok := parsePromSample("phoenix_router_dispatch_stop_duration_count{route=\"/x\"} notanumber"); ok {
		t.Error("a non-numeric value must not parse")
	}
}

// TestRouteLatencyArgs pins the flag surface, including the --min-uptime knob
// the refusal is measured against.
func TestRouteLatencyArgs(t *testing.T) {
	_, _, _, min, err := parseRouteLatencyArgs(nil)
	if err != nil || min != routeLatencyMinUptimeDefault {
		t.Fatalf("default min-uptime = %d, err = %v", min, err)
	}
	n, u, tok, min, err := parseRouteLatencyArgs([]string{"--name=g", "--url", "http://x", "--token=t", "--min-uptime", "30"})
	if err != nil || n != "g" || u != "http://x" || tok != "t" || min != 30 {
		t.Fatalf("parsed (%q,%q,%q,%d) err=%v", n, u, tok, min, err)
	}
	if _, _, _, _, err := parseRouteLatencyArgs([]string{"--min-uptime", "soon"}); err == nil {
		t.Error("a non-numeric --min-uptime must be a usage error")
	}
	if _, _, _, _, err := parseRouteLatencyArgs([]string{"boom"}); err == nil {
		t.Error("a positional must be a usage error")
	}
}
