package cli

// cloud_status_cmd.go is `bp cloud status` — the terminal triage twin of the
// dashboard's attention queue (epic charter, decision 15). It fetches the whole
// fleet from the control plane (GET /v1/barkparks via internal/cloudclient) and
// renders it RANK-ORDERED, most-urgent-first, bucketed into attention /
// in-flight / healthy, each status cell painted via the shared statusRole colors
// so a red row in the terminal and a red dot in the dashboard mean the same
// thing. `-o json` emits the same ranked structure for scripts.
//
// The rank order IS the charter-pinned decision-15 spec — the SAME ordering the
// SPA's statusOf/attentionRank implements — reproduced byte-for-byte by the
// committed testdata/attention_order.json fixture, which is the cross-surface
// contract a second surface implements against without reading this one.

import (
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// attentionStatus classifies one Barkpark into its charter-decision-15 status
// label. The eight labels, MOST URGENT FIRST, are:
//
//  1. removal_failed — deprovision_status = "failed"
//  2. failed         — no host && provision_status = "failed"
//  3. suspended      — suspended = true (and not removing)
//  4. degraded       — live && (health_status != "up" || agent_status != "online")
//  5. behind         — live && update_state = "behind"
//  6. removing       — deprovision_status ∈ {pending, claimed}
//  7. provisioning   — no host, nothing failed
//  8. ok             — live, healthy, current
//
// where "live" = a host is set with nothing in-flight/failed/suspended. The
// cases are evaluated in rank order and the first match wins, so the precedence
// (a removing box that is also suspended is "removing"; a live box that is both
// degraded and behind is "degraded") falls out of the ordering itself.
func attentionStatus(b cloudclient.Barkpark) string {
	host := strings.TrimSpace(b.Host)
	removing := b.DeprovisionStatus == "pending" || b.DeprovisionStatus == "claimed"
	// live: a real host, no in-flight removal, not suspended, not a failed provision.
	live := host != "" && !removing && !b.Suspended && b.ProvisionStatus != "failed"

	switch {
	case b.DeprovisionStatus == "failed":
		return "removal_failed"
	case host == "" && b.ProvisionStatus == "failed":
		return "failed"
	case b.Suspended && !removing:
		return "suspended"
	case live && (b.HealthStatus != "up" || b.AgentStatus != "online"):
		return "degraded"
	case live && b.UpdateState == "behind":
		return "behind"
	case removing:
		return "removing"
	case host == "":
		return "provisioning"
	default:
		return "ok"
	}
}

// attentionRankOrder is the decision-15 ordering, most-urgent (0) to least (7).
// The slice index IS the sort key attentionRank returns.
var attentionRankOrder = []string{
	"removal_failed", // 0
	"failed",         // 1
	"suspended",      // 2
	"degraded",       // 3
	"behind",         // 4
	"removing",       // 5
	"provisioning",   // 6
	"ok",             // 7
}

// attentionRank is the sort key for a status label — its index in
// attentionRankOrder. An unknown label sorts last (len), never panics.
func attentionRank(status string) int {
	for i, s := range attentionRankOrder {
		if s == status {
			return i
		}
	}
	return len(attentionRankOrder)
}

// attentionBucket groups a status into the three charter buckets: attention
// (ranks 1–5: removal_failed…behind), in-flight (6–7: removing/provisioning),
// healthy (8: ok).
func attentionBucket(status string) string {
	switch status {
	case "removing", "provisioning":
		return "in_flight"
	case "ok":
		return "healthy"
	default:
		// removal_failed, failed, suspended, degraded, behind — and any unknown
		// label defensively surfaces in the attention bucket rather than hiding.
		return "attention"
	}
}

// rankedBarkpark is one fleet row with its computed decision-15 triage fields.
type rankedBarkpark struct {
	BP     cloudclient.Barkpark
	Status string
	Bucket string
	Rank   int
}

// rankBarkparks classifies every Barkpark and returns them in decision-15 rank
// order: by rank ascending (most urgent first), tiebroken by name ascending
// case-insensitively. This is the pure ordering the attention_order.json fixture
// pins and the SPA mirrors.
func rankBarkparks(list []cloudclient.Barkpark) []rankedBarkpark {
	out := make([]rankedBarkpark, 0, len(list))
	for _, b := range list {
		st := attentionStatus(b)
		out = append(out, rankedBarkpark{BP: b, Status: st, Bucket: attentionBucket(st), Rank: attentionRank(st)})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Rank != out[j].Rank {
			return out[i].Rank < out[j].Rank
		}
		// Tiebreak: name ascending, case-insensitive (charter decision 15).
		ni, nj := strings.ToLower(out[i].BP.Name), strings.ToLower(out[j].BP.Name)
		if ni != nj {
			return ni < nj
		}
		// Total order even for same-name rows: fall back to id so the sort is
		// deterministic (SliceStable would otherwise keep input order).
		return out[i].BP.ID < out[j].BP.ID
	})
	return out
}

// rankedBarkparkRow is the flat JSON/YAML shape of one ranked row — self-
// describing so `-o json` output is stable and scriptable.
func rankedBarkparkRow(r rankedBarkpark) map[string]any {
	return map[string]any{
		"name":          r.BP.Name,
		"slug":          r.BP.Slug,
		"id":            r.BP.ID,
		"host":          r.BP.Host,
		"url":           r.BP.URL,
		"status":        r.Status,
		"bucket":        r.Bucket,
		"rank":          r.Rank,
		"health_status": r.BP.HealthStatus,
		"agent_status":  r.BP.AgentStatus,
		"update_state":  r.BP.UpdateState,
		"suspended":     r.BP.Suspended,
	}
}

// bucketCounts tallies a ranked fleet into the three buckets.
func bucketCounts(ranked []rankedBarkpark) (attention, inFlight, healthy int) {
	for _, r := range ranked {
		switch r.Bucket {
		case "attention":
			attention++
		case "in_flight":
			inFlight++
		case "healthy":
			healthy++
		}
	}
	return
}

// runCloudStatus is `bp cloud status`: fetch the fleet from the control plane
// and render the decision-15 triage view. Requires a Cloud token (`bp login`).
func runCloudStatus(out *writer, g globals, args []string) int {
	if g.help {
		printCloudStatusHelp(out)
		return exitOK
	}
	if len(args) > 0 {
		return useError(out, "usage", "bp cloud status takes no arguments (run `bp cloud status -h` for usage)", exitUsage)
	}

	cfg, err := LoadConfig()
	if err != nil {
		return useError(out, "failed", "read config: "+err.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to see your fleet's status", exitAuth)
	}

	list, lerr := cfg.CloudClient().ListBarkparks(cloudCtx())
	if lerr != nil {
		return cloudFail(out, "fleet status", lerr)
	}
	ranked := rankBarkparks(list)
	attention, inFlight, healthy := bucketCounts(ranked)

	if out.output == "json" || out.output == "yaml" {
		rows := make([]any, 0, len(ranked))
		for _, r := range ranked {
			rows = append(rows, rankedBarkparkRow(r))
		}
		out.emitStructured(map[string]any{
			"ok":    true,
			"count": len(ranked),
			"buckets": map[string]any{
				"attention": attention,
				"in_flight": inFlight,
				"healthy":   healthy,
			},
			"barkparks": rows,
		})
		return exitOK
	}

	if len(ranked) == 0 {
		out.outf("no Barkparks yet — launch one with 'bp go-live --name <name>' or 'bp launch hetzner --name <name>'")
		return exitOK
	}

	out.outf("%d barkpark(s) · %d need attention · %d in-flight · %d healthy",
		len(ranked), attention, inFlight, healthy)
	renderStatusBucket(out, "ATTENTION", "attention", ranked)
	renderStatusBucket(out, "IN-FLIGHT", "in_flight", ranked)
	renderStatusBucket(out, "HEALTHY", "healthy", ranked)
	return exitOK
}

// renderStatusBucket prints one bucket section (header + painted table) when it
// has rows, in the already-sorted order. Silent for an empty bucket so the view
// stays lean.
func renderStatusBucket(out *writer, title, bucket string, ranked []rankedBarkpark) {
	rows := make([]rankedBarkpark, 0)
	for _, r := range ranked {
		if r.Bucket == bucket {
			rows = append(rows, r)
		}
	}
	if len(rows) == 0 {
		return
	}
	out.outf("")
	out.outf("%s (%d)", title, len(rows))
	renderStatusRows(out, rows)
}

// statusDash renders an empty status field as an em dash so columns stay
// scannable (the hzCell idiom), leaving non-empty values untouched.
func statusDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return sanitizeCell(s)
}

// renderStatusRows prints the fleet rows as an aligned, status-painted table.
// Widths are measured on BARE strings; each cell is then painted via
// out.paintCell (a no-op when color is off), so alignment is exact and
// --no-color / piped output carries no ANSI. STATUS/HEALTH/AGENT paint by their
// role; NAME/URL match no role and stay plain.
func renderStatusRows(out *writer, rows []rankedBarkpark) {
	headers := []string{"STATUS", "NAME", "HEALTH", "AGENT", "URL"}
	cells := make([][]string, 0, len(rows))
	for _, r := range rows {
		url := r.BP.URL
		if strings.TrimSpace(url) == "" {
			url = r.BP.Host
		}
		cells = append(cells, []string{
			r.Status,
			statusDash(r.BP.Name),
			statusDash(r.BP.HealthStatus),
			statusDash(r.BP.AgentStatus),
			statusDash(url),
		})
	}
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = runewidth.StringWidth(h)
	}
	for _, row := range cells {
		for i, c := range row {
			if n := runewidth.StringWidth(c); n > widths[i] {
				widths[i] = n
			}
		}
	}
	out.outf("%s", joinCols(headers, widths))
	for _, row := range cells {
		out.outf("%s", joinColsPainted(out, row, widths))
	}
}

// printCloudStatusHelp writes `bp cloud status` usage.
func printCloudStatusHelp(out *writer) {
	const help = `bp cloud status — your fleet, triaged (charter decision 15).

USAGE
  bp cloud status [-o table|json|yaml]

WHAT IT SHOWS
  every Barkpark in your team's fleet, ranked most-urgent first and bucketed:

    ATTENTION   removal_failed · failed · suspended · degraded · behind
    IN-FLIGHT   removing · provisioning
    HEALTHY     ok

  Status cells are colored by role (red = danger, yellow = warn, cyan = in
  flight, green = ok) on a tty; piped or --no-color output is plain text.
  Requires 'bp login'. The rank order is the same one the cloud dashboard's
  attention queue uses — one triage vocabulary, two surfaces.

OUTPUT
  -o table   ranked, bucketed, colored (default on a tty)
  -o json    the ranked structure: {ok, count, buckets, barkparks[]}
  -o yaml    the same, as YAML`
	out.outf("%s", help)
}
