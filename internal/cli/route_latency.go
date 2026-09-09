package cli

// route_latency.go — the PURE half of `bp latency`: parse the Prometheus text
// exposition the instance serves at `GET /v1/instance/metrics` and fold the
// per-route dispatch histogram into a ranked, named answer.
//
// WHY THIS EXISTS. The fleet's only latency reader was the health beat's
// `p95_ms` scalar (cloud/lib/barkpark_cloud/telemetry.ex:137, metered in
// usage.ex:141/213). That scalar is a 60-second rolling window over a box doing
// 1–3 req/s: its "p95" is the 4th-slowest of ~66 samples, three of five boxes
// emit the -1 unmeasured sentinel, and on an UNCHANGED box it walked
// 1055 → 341 → 125 → 99 → 1145 ms in ten minutes purely because a verifier
// added traffic. It is a low-traffic proxy wearing a latency word, and it is
// box-level: it can never say WHICH route is slow.
//
// `phoenix_router_dispatch_stop_duration_bucket{route="…",le="…"}` has neither
// defect. It is a real cumulative histogram, tagged by route
// (api/lib/barkpark_web/telemetry.ex `prometheus_metrics/0`), accumulated since
// the slot's BEAM booted, and it was read by NOTHING — 516 lines served to no
// eyes. This file reads it.
//
// THE WINDOW IS THE CATCH. Cumulative-since-boot is a different quantity from
// "right now": a freshly swapped slot has a handful of samples and a histogram
// whose quantile is an artefact of whoever curled it first. So the command that
// wraps this refuses to print a number until the slot is old enough, and always
// states the window it is quoting. See routeLatencyCmd in route_latency_cmd.go.

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

// routeLatencyMetric is the histogram family this reader consumes. The three
// series it emits are `<family>_bucket`, `<family>_sum` and `<family>_count`.
const routeLatencyMetric = "phoenix_router_dispatch_stop_duration"

// histBucket is one cumulative bucket: every observation <= LE, as of the
// scrape. LE is +Inf for the terminal bucket.
type histBucket struct {
	LE  float64
	Cum float64
}

// routeLatency is one route's fold of the cumulative histogram. Count and SumMS
// come from the `_count` / `_sum` series; Buckets from `_bucket`, sorted
// ascending by LE with +Inf last.
type routeLatency struct {
	Route   string
	Count   float64
	SumMS   float64
	Buckets []histBucket
}

// MeanMS is the arithmetic mean over the whole cumulative window, or NaN when
// the route has no observations. Never a fabricated 0 — a route nothing hit is
// not a route that answered in 0 ms.
func (r routeLatency) MeanMS() float64 {
	if r.Count <= 0 {
		return math.NaN()
	}
	return r.SumMS / r.Count
}

// quantileEstimate is a histogram quantile with its BRACKET kept. The bracket is
// the honest part: a histogram cannot tell you a percentile, only which bucket
// it fell in, and the interpolated MS is a linear guess INSIDE Lower..Upper.
// Bounded is false when the quantile landed in the terminal +Inf bucket — there
// is no upper edge to interpolate against, so MS stays NaN and a renderer must
// say "> Lower", never invent a number.
type quantileEstimate struct {
	Lower   float64
	Upper   float64
	MS      float64
	Bounded bool
	Known   bool // false when the route has no observations at all
}

// quantile estimates q (0<q<1) over the cumulative buckets, Prometheus
// `histogram_quantile` style: find the first bucket whose cumulative count
// reaches rank = q * total, then interpolate linearly between that bucket's
// lower and upper edge.
func (r routeLatency) quantile(q float64) quantileEstimate {
	if r.Count <= 0 || len(r.Buckets) == 0 {
		return quantileEstimate{}
	}
	// The terminal bucket's cumulative count is the population the buckets
	// actually saw. Prefer it over `_count` so a scrape that raced a concurrent
	// observation cannot push the rank past the last bucket.
	total := r.Buckets[len(r.Buckets)-1].Cum
	if total <= 0 {
		return quantileEstimate{}
	}
	rank := q * total
	prevLE := 0.0
	prevCum := 0.0
	for _, b := range r.Buckets {
		if b.Cum < rank {
			prevLE, prevCum = b.LE, b.Cum
			continue
		}
		if math.IsInf(b.LE, 1) {
			return quantileEstimate{Lower: prevLE, Upper: math.Inf(1), MS: math.NaN(), Known: true}
		}
		width := b.LE - prevLE
		inBucket := b.Cum - prevCum
		ms := b.LE
		if width > 0 && inBucket > 0 {
			ms = prevLE + width*((rank-prevCum)/inBucket)
		}
		return quantileEstimate{Lower: prevLE, Upper: b.LE, MS: ms, Bounded: true, Known: true}
	}
	last := r.Buckets[len(r.Buckets)-1]
	return quantileEstimate{Lower: last.LE, Upper: math.Inf(1), MS: math.NaN(), Known: true}
}

// sortKey ranks routes worst-first. An UNBOUNDED p95 (the quantile fell off the
// top of the bucket ladder) always outranks any bounded one — "slower than the
// widest bucket we measure" is strictly worse than any number inside it — and
// unbounded routes rank against each other by mean.
func (r routeLatency) sortKey() (unbounded bool, primary float64, mean float64) {
	q := r.quantile(0.95)
	m := r.MeanMS()
	if math.IsNaN(m) {
		m = 0
	}
	if !q.Known {
		return false, -1, m
	}
	if !q.Bounded {
		return true, math.Max(q.Lower, m), m
	}
	return false, q.MS, m
}

// parseRouteLatency folds a Prometheus text exposition into one routeLatency
// per route, ranked worst-first. Lines outside the histogram family are
// ignored, as are comments and anything malformed — a scrape is 500+ lines of
// unrelated series and one unparsable line must not lose the rest.
func parseRouteLatency(exposition string) []routeLatency {
	byRoute := map[string]*routeLatency{}

	get := func(route string) *routeLatency {
		if r, ok := byRoute[route]; ok {
			return r
		}
		r := &routeLatency{Route: route}
		byRoute[route] = r
		return r
	}

	for _, line := range strings.Split(exposition, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, labels, value, ok := parsePromSample(line)
		if !ok || !strings.HasPrefix(name, routeLatencyMetric+"_") {
			continue
		}
		route, hasRoute := labels["route"]
		if !hasRoute || route == "" {
			continue
		}
		switch strings.TrimPrefix(name, routeLatencyMetric+"_") {
		case "bucket":
			le, err := parsePromLE(labels["le"])
			if err != nil {
				continue
			}
			r := get(route)
			r.Buckets = append(r.Buckets, histBucket{LE: le, Cum: value})
		case "sum":
			get(route).SumMS = value
		case "count":
			get(route).Count = value
		}
	}

	out := make([]routeLatency, 0, len(byRoute))
	for _, r := range byRoute {
		sort.Slice(r.Buckets, func(i, j int) bool { return r.Buckets[i].LE < r.Buckets[j].LE })
		out = append(out, *r)
	}
	sort.Slice(out, func(i, j int) bool {
		ui, pi, mi := out[i].sortKey()
		uj, pj, mj := out[j].sortKey()
		if ui != uj {
			return ui
		}
		if pi != pj {
			return pi > pj
		}
		if mi != mj {
			return mi > mj
		}
		return out[i].Route < out[j].Route
	})
	return out
}

// parsePromSample splits one Prometheus exposition line into its metric name,
// label map and float value. ok is false for anything that is not a well-formed
// sample.
func parsePromSample(line string) (name string, labels map[string]string, value float64, ok bool) {
	labels = map[string]string{}

	open := strings.IndexByte(line, '{')
	var rest string
	if open < 0 {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			return "", nil, 0, false
		}
		name, rest = fields[0], fields[1]
	} else {
		close := strings.LastIndexByte(line, '}')
		if close < open {
			return "", nil, 0, false
		}
		name = strings.TrimSpace(line[:open])
		for k, v := range parsePromLabels(line[open+1 : close]) {
			labels[k] = v
		}
		rest = strings.TrimSpace(line[close+1:])
		if f := strings.Fields(rest); len(f) > 0 {
			rest = f[0]
		}
	}

	v, err := strconv.ParseFloat(rest, 64)
	if err != nil {
		return "", nil, 0, false
	}
	return name, labels, v, true
}

// parsePromLabels reads a `k="v",k2="v2"` label body. Commas inside a quoted
// value are respected; a backslash escape passes its next byte through.
func parsePromLabels(body string) map[string]string {
	out := map[string]string{}
	i := 0
	for i < len(body) {
		for i < len(body) && (body[i] == ',' || body[i] == ' ') {
			i++
		}
		eq := strings.IndexByte(body[i:], '=')
		if eq < 0 {
			return out
		}
		key := strings.TrimSpace(body[i : i+eq])
		i += eq + 1
		if i >= len(body) || body[i] != '"' {
			return out
		}
		i++
		var val strings.Builder
		for i < len(body) && body[i] != '"' {
			if body[i] == '\\' && i+1 < len(body) {
				i++
			}
			val.WriteByte(body[i])
			i++
		}
		i++ // closing quote
		out[key] = val.String()
	}
	return out
}

// parsePromLE reads a bucket's `le` label, mapping the textual infinities onto
// math.Inf so the terminal bucket sorts last.
func parsePromLE(s string) (float64, error) {
	switch strings.TrimSpace(s) {
	case "+Inf", "Inf", "inf", "+inf":
		return math.Inf(1), nil
	}
	return strconv.ParseFloat(strings.TrimSpace(s), 64)
}
