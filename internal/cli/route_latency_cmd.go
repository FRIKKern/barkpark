package cli

// route_latency_cmd.go — `bp latency`, the FIRST consumer of the per-route
// dispatch histogram the instance has been serving to nobody.
//
// WHERE THIS LIVES, AND WHY IT IS NOT IN cloud/. The existing latency reader is
// cloud-side (`BarkparkCloud.Telemetry.normalize/1` lifts `p95_ms` out of the
// agent's health beat; `BarkparkCloud.Usage` meters it). That reader is PUSH-fed:
// the on-box agent POSTs a beat, the router lands it as an `AgentEvent`, and the
// control plane folds rows it already has. The control plane never scrapes a box
// — there is no outbound HTTP-to-instance seam anywhere in `cloud/`, and the
// beat carries no per-route text to fold, so a cloud-side consumer would have to
// invent both a new egress path and a new agent payload. `bp` already holds an
// authenticated client for exactly this box (`bp doctor` probes its HTTP surface
// directly, resolving base URL + bearer the same way), and the histogram is
// already Bearer-authed on that same seam. So the consumer is a CLI reader.
//
// THE REFUSAL. `phoenix_router_dispatch_stop_duration` is cumulative since the
// slot's BEAM booted. On a slot that just swapped, its quantile is an artefact of
// whoever curled it first, and a blue/green deploy resets it to zero. This
// command therefore states its window on every run and REFUSES — prints no
// latency figure at all — when the slot is younger than --min-uptime. The window
// itself is read from the box's own `GET /status.json` `uptime_seconds`
// (`Barkpark.Status.node_uptime_seconds/0`, BEAM wall clock); when that cannot be
// read the command refuses too, because a number whose window is unknown is the
// exact defect `p95_ms` already has.

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// routeLatencyMinUptimeDefault is the slot age below which no figure is printed.
// Ten minutes is the smallest window in which the box's own 60s health beat has
// produced ten samples; below it the cumulative histogram is dominated by boot
// traffic and by whoever probed the slot first.
const routeLatencyMinUptimeDefault = 600

// routeLatencyClient is the HTTP client both probes use. A package var so tests
// can shorten the timeout; the command itself never knows it was swapped.
var routeLatencyClient = &http.Client{Timeout: 20 * time.Second}

// routeLatencyWindow is what the box says about the span the histogram covers.
type routeLatencyWindow struct {
	UptimeSeconds float64
	Known         bool
	Commit        string
	Version       string
}

// runRouteLatency is `bp latency [--name <handle>] [--url <url>] [--token <tok>]
// [--min-uptime <seconds>]`.
func runRouteLatency(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printRouteLatencyHelp(out)
			return exitOK
		}
	}

	name, urlOverride, tokenOverride, minUptime, perr := parseRouteLatencyArgs(args)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}

	// `--token` is a GLOBAL flag (globals.go valueFlags), so parseGlobals consumes
	// it before this command's own parser ever sees it — a command-local --token
	// is unreachable in a real `bp latency --token X` invocation and the value
	// arrives on g instead. Prefer a locally-set one, fall back to the global, so
	// both spellings reach the same bearer. Without this the flag is silently
	// dropped and the saved token is used in its place, which is a live 401
	// against a platform-operator-gated route.
	if strings.TrimSpace(tokenOverride) == "" {
		tokenOverride = g.token
	}

	base, token, target, ok := resolveDoctorTarget(out, name, urlOverride, tokenOverride)
	if !ok {
		return exitUsage
	}

	win, werr := fetchRouteLatencyWindow(base)
	if werr != nil || !win.Known {
		reason := "the box did not report uptime_seconds"
		if werr != nil {
			reason = werr.Error()
		}
		return refuseRouteLatency(out, target, base, win, minUptime, "unknown_window",
			"cannot state the window this histogram covers ("+reason+") — "+
				"a latency number whose window is unknown is exactly the defect this reader exists to avoid")
	}

	if win.UptimeSeconds < float64(minUptime) {
		return refuseRouteLatency(out, target, base, win, minUptime, "slot_too_young",
			fmt.Sprintf("the slot booted %s ago; this histogram is cumulative SINCE BOOT, so its quantiles "+
				"are still an artefact of boot traffic. Re-run in %s, or lower --min-uptime deliberately.",
				humanDuration(win.UptimeSeconds),
				humanDuration(float64(minUptime)-win.UptimeSeconds)))
	}

	body, herr := fetchRouteLatencyMetrics(base, token)
	if herr != nil {
		return useError(out, "failed", "scrape "+base+"/v1/instance/metrics: "+herr.Error(), exitGeneric)
	}

	routes := parseRouteLatency(body)
	measured := make([]routeLatency, 0, len(routes))
	for _, r := range routes {
		if r.Count > 0 {
			measured = append(measured, r)
		}
	}
	if len(measured) == 0 {
		return refuseRouteLatency(out, target, base, win, minUptime, "no_samples",
			"the histogram carries no route with an observation — "+routeLatencyMetric+
				" is exposed but nothing has been dispatched through it on this slot")
	}

	switch out.output {
	case "json":
		out.renderJSON(routeLatencyJSON(target, base, win, measured))
		return exitOK
	case "yaml":
		out.renderYAML(toGeneric(routeLatencyJSON(target, base, win, measured)))
		return exitOK
	}
	renderRouteLatency(out, target, base, win, measured)
	return exitOK
}

// refuseRouteLatency is the ONE exit that prints no latency figure. It names the
// window, the observed uptime, and what would make the read legitimate.
func refuseRouteLatency(out *writer, target, base string, win routeLatencyWindow, minUptime int, code, msg string) int {
	observed := "unknown"
	if win.Known {
		observed = humanDuration(win.UptimeSeconds)
	}
	m := map[string]any{
		"ok":     false,
		"target": target,
		"window": map[string]any{
			"kind":               "cumulative_since_slot_boot",
			"uptime_seconds":     routeLatencyUptimeJSON(win),
			"min_uptime_seconds": minUptime,
			"uptime_human":       observed,
			"sufficient":         false,
		},
		"error": map[string]any{"code": code, "message": msg},
	}
	switch out.output {
	case "json":
		out.renderJSON(m)
		return exitGeneric
	case "yaml":
		out.renderYAML(toGeneric(m))
		return exitGeneric
	}
	out.outf("bp latency — %s (%s)", target, base)
	out.outf("  window: cumulative since slot boot; observed uptime %s, minimum %s",
		observed, humanDuration(float64(minUptime)))
	out.userErr("REFUSED (%s): %s", code, msg)
	out.errf("   no latency figure printed — a number over an unqualified window is the thing this reader replaces.")
	return exitGeneric
}

// routeLatencyUptimeJSON keeps "we did not measure" out of the number space:
// nil, never 0, when the box never told us its uptime.
func routeLatencyUptimeJSON(win routeLatencyWindow) any {
	if !win.Known {
		return nil
	}
	return win.UptimeSeconds
}

// renderRouteLatency prints the human report: the window it is quoting, one row
// per route worst-first, then the verdict that NAMES the slow route.
func renderRouteLatency(out *writer, target, base string, win routeLatencyWindow, routes []routeLatency) {
	out.outf("bp latency — %s (%s)", target, base)
	commit := win.Commit
	if commit == "" {
		commit = "unknown"
	}
	out.outf("  window: cumulative since slot boot — %s of uptime (commit %s)", humanDuration(win.UptimeSeconds), commit)
	out.outf("  source: %s{route=…} via GET /v1/instance/metrics", routeLatencyMetric)
	out.outf("  every figure below covers that WHOLE window, not a live rate.")
	out.outf("")
	out.outf("  %s %8s %10s %12s  %s", padRight("ROUTE", 40), "COUNT", "MEAN", "p95", "p95 BUCKET")
	for _, r := range routes {
		q := r.quantile(0.95)
		out.outf("  %s %8s %10s %12s  %s",
			padRight(r.Route, 40),
			strconv.FormatFloat(r.Count, 'f', -1, 64),
			formatMS(r.MeanMS()),
			formatQuantile(q),
			formatBucket(q))
	}
	out.outf("")
	worst := routes[0]
	q := worst.quantile(0.95)
	out.outf("=> SLOWEST: %s — p95 %s (mean %s over %s requests since slot boot)",
		worst.Route, formatQuantile(q), formatMS(worst.MeanMS()),
		strconv.FormatFloat(worst.Count, 'f', -1, 64))
}

// routeLatencyJSON is the machine envelope. `p95_ms` is null — never a
// fabricated number — when the quantile fell into the terminal +Inf bucket;
// `p95_gt_ms` carries what IS known in that case.
func routeLatencyJSON(target, base string, win routeLatencyWindow, routes []routeLatency) map[string]any {
	rows := make([]map[string]any, 0, len(routes))
	for _, r := range routes {
		q := r.quantile(0.95)
		row := map[string]any{
			"route":   r.Route,
			"count":   r.Count,
			"sum_ms":  r.SumMS,
			"mean_ms": nanToNil(r.MeanMS()),
		}
		if q.Bounded {
			row["p95_ms"] = q.MS
			row["p95_bucket_lower_ms"] = q.Lower
			row["p95_bucket_upper_ms"] = q.Upper
		} else {
			row["p95_ms"] = nil
			row["p95_gt_ms"] = q.Lower
			row["p95_bucket_lower_ms"] = q.Lower
			row["p95_bucket_upper_ms"] = nil
		}
		rows = append(rows, row)
	}
	return map[string]any{
		"ok":     true,
		"target": target,
		"window": map[string]any{
			"kind":           "cumulative_since_slot_boot",
			"uptime_seconds": routeLatencyUptimeJSON(win),
			"uptime_human":   humanDuration(win.UptimeSeconds),
			"commit":         win.Commit,
			"sufficient":     true,
		},
		"base_url": base,
		"metric":   routeLatencyMetric,
		"slowest":  routes[0].Route,
		"routes":   rows,
	}
}

func nanToNil(f float64) any {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return nil
	}
	return f
}

func formatMS(f float64) string {
	if math.IsNaN(f) {
		return "—"
	}
	return strconv.FormatFloat(f, 'f', 0, 64) + " ms"
}

// formatQuantile renders a p95. An unbounded one is rendered as a STRICT LOWER
// BOUND, never a number: the top bucket has no upper edge and interpolating
// against infinity is how a histogram gets used to fabricate a figure.
func formatQuantile(q quantileEstimate) string {
	if !q.Known {
		return "—"
	}
	if !q.Bounded {
		return "> " + routeLatencyNum(q.Lower) + " ms"
	}
	return strconv.FormatFloat(q.MS, 'f', 0, 64) + " ms"
}

func formatBucket(q quantileEstimate) string {
	if !q.Known {
		return "—"
	}
	if !q.Bounded {
		return routeLatencyNum(q.Lower) + "–∞ ms"
	}
	return routeLatencyNum(q.Lower) + "–" + routeLatencyNum(q.Upper) + " ms"
}

func routeLatencyNum(f float64) string {
	if math.IsInf(f, 1) {
		return "∞"
	}
	return strconv.FormatFloat(f, 'f', -1, 64)
}

// humanDuration renders a span of seconds as `4h 12m 03s` / `7m 22s` / `42s`.
func humanDuration(seconds float64) string {
	if math.IsNaN(seconds) || seconds < 0 {
		return "unknown"
	}
	total := int64(seconds)
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	switch {
	case h > 0:
		return fmt.Sprintf("%dh %02dm %02ds", h, m, s)
	case m > 0:
		return fmt.Sprintf("%dm %02ds", m, s)
	default:
		return fmt.Sprintf("%ds", s)
	}
}

// fetchRouteLatencyWindow reads the box's PUBLIC status endpoint for the span
// the histogram covers. `uptime_seconds` is BEAM wall clock
// (Barkpark.Status.node_uptime_seconds/0), which is exactly "since this slot
// booted" — the same event that zeroes the histogram.
func fetchRouteLatencyWindow(base string) (routeLatencyWindow, error) {
	req, err := http.NewRequest(http.MethodGet, base+"/status.json", nil)
	if err != nil {
		return routeLatencyWindow{}, err
	}
	resp, err := routeLatencyClient.Do(req)
	if err != nil {
		return routeLatencyWindow{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return routeLatencyWindow{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return routeLatencyWindow{}, fmt.Errorf("GET %s/status.json returned %d", base, resp.StatusCode)
	}
	var payload struct {
		UptimeSeconds *float64 `json:"uptime_seconds"`
		Commit        string   `json:"commit"`
		Version       string   `json:"version"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return routeLatencyWindow{}, fmt.Errorf("decode %s/status.json: %w", base, err)
	}
	win := routeLatencyWindow{Commit: payload.Commit, Version: payload.Version}
	if payload.UptimeSeconds != nil {
		win.UptimeSeconds = *payload.UptimeSeconds
		win.Known = true
	}
	return win, nil
}

// fetchRouteLatencyMetrics scrapes the Bearer-gated Prometheus exposition.
func fetchRouteLatencyMetrics(base, token string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, base+"/v1/instance/metrics", nil)
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(token) != "" {
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(token))
	}
	resp, err := routeLatencyClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("returned %d (the route is platform-operator gated; pass --token)", resp.StatusCode)
	}
	return string(body), nil
}

// parseRouteLatencyArgs splits `bp latency` flags. Any positional or unknown
// flag is a usage error.
func parseRouteLatencyArgs(args []string) (name, url, token string, minUptime int, err error) {
	minUptime = routeLatencyMinUptimeDefault
	for i := 0; i < len(args); i++ {
		a := args[i]
		var raw string
		switch {
		case a == "--name":
			name, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--name="):
			name = a[len("--name="):]
		case a == "--url":
			url, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--url="):
			url = a[len("--url="):]
		case a == "--token":
			token, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--token="):
			token = a[len("--token="):]
		case a == "--min-uptime":
			raw, i, err = nextFlagValue(args, i)
		case strings.HasPrefix(a, "--min-uptime="):
			raw = a[len("--min-uptime="):]
		default:
			return "", "", "", 0, errRouteLatencyUsage(a)
		}
		if err != nil {
			return "", "", "", 0, err
		}
		if raw != "" {
			n, cerr := strconv.Atoi(strings.TrimSpace(raw))
			if cerr != nil || n < 0 {
				return "", "", "", 0, &usageErr{"--min-uptime takes a non-negative number of seconds, got " + quote(raw)}
			}
			minUptime = n
		}
	}
	return name, url, token, minUptime, nil
}

func errRouteLatencyUsage(a string) error {
	return &usageErr{"unexpected argument " + quote(a) +
		" (usage: bp latency [--name <handle>] [--url <url>] [--token <tok>] [--min-uptime <seconds>])"}
}

func printRouteLatencyHelp(out *writer) {
	const help = `bp latency — name WHICH route is slow on a Barkpark, from the per-route histogram.

USAGE
  bp latency [--name <handle>] [--url <url>] [--token <token>] [--min-uptime <seconds>]

WHAT IT DOES
  scrapes phoenix_router_dispatch_stop_duration{route=…} from the target's
  Bearer-gated GET /v1/instance/metrics, folds it per route, and ranks the routes
  worst-first by p95 — so the answer is "/v1/graph p95 > 5000 ms", not "the box
  p95 is 32.8 s". The box-level p95_ms on the health beat is a 60-second rolling
  window over a box doing 1-3 req/s; it cannot name a route and it moves when a
  bystander adds traffic.

THE WINDOW
  This histogram is CUMULATIVE SINCE SLOT BOOT — a blue/green swap resets it. The
  command prints the window on every run (read from the target's own
  /status.json uptime_seconds) and REFUSES to print any figure when the slot is
  younger than --min-uptime (default 600s), or when the window cannot be read at
  all. A refusal exits non-zero and prints no number.

TARGET
  --url <url>      probe this base URL directly (overrides config)
  --name <handle>  probe a known Barkpark by name (else the active server)
  --token <token>  bearer for /v1/instance/metrics (a GLOBAL flag; else the saved one)

FLAGS
  --min-uptime <s> minimum slot age before any figure is printed (default 600)
  -o json          emit one machine-readable JSON object on stdout
  -o yaml          emit one machine-readable YAML document on stdout

SEE ALSO
  bp doctor        the readiness battery against the same target`
	out.outf("%s", help)
}
