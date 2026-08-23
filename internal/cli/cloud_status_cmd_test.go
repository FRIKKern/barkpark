package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// f64 / str are pointer helpers for building a Pressure block in a test — the
// whole block is pointers on purpose (nil = UNMETERED, never 0).
func f64(v float64) *float64  { return &v }
func strPtr(v string) *string { return &v }

// seen is the last_seen_at every LIVE test box needs: a live box the control
// plane has never heard from ranks `unreported` (charter D69, mirroring the
// console's classifyBp precedence), so an omitted last_seen_at is a REAL input,
// not a neutral default.
const seen = "2026-08-06T12:00:00Z"

// pressed builds a beating box with the given vitals. cores/load15/load1/disk
// are passed as pointers so a case can say "did not measure" precisely.
func pressed(name string, p *cloudclient.Pressure) cloudclient.Barkpark {
	return cloudclient.Barkpark{
		ID: name, Name: name, Host: "h", LastSeenAt: seen,
		HealthStatus: "up", AgentStatus: "online", UpdateState: "current",
		Pressure: p,
	}
}

// TestAttentionStatusClassification pins the decision-15 / D69 label for each
// rank, including the precedence edges (removing beats suspended; unreported is
// tested before the cached health columns; degraded beats strained beats
// filling beats behind; a host-set failed provision is not "live").
func TestAttentionStatusClassification(t *testing.T) {
	live := func(b cloudclient.Barkpark) cloudclient.Barkpark { b.LastSeenAt = seen; return b }
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"removal_failed", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "failed"}, "removal_failed"},
		{"removal_failed beats everything", cloudclient.Barkpark{Host: "h", Suspended: true, DeprovisionStatus: "failed"}, "removal_failed"},
		{"failed needs no host", cloudclient.Barkpark{Host: "", ProvisionStatus: "failed"}, "failed"},
		{"suspended", cloudclient.Barkpark{Host: "h", Suspended: true}, "suspended"},
		{"suspended+removing is removing", cloudclient.Barkpark{Host: "h", Suspended: true, DeprovisionStatus: "pending"}, "removing"},
		{"degraded via health", live(cloudclient.Barkpark{Host: "h", HealthStatus: "unknown", AgentStatus: "online"}), "degraded"},
		{"degraded via agent", live(cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "offline"}), "degraded"},
		{"degraded beats behind", live(cloudclient.Barkpark{Host: "h", HealthStatus: "down", AgentStatus: "online", UpdateState: "behind"}), "degraded"},
		{"behind", live(cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online", UpdateState: "behind"}), "behind"},
		{"removing pending", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "pending"}, "removing"},
		{"removing claimed", cloudclient.Barkpark{Host: "h", DeprovisionStatus: "claimed"}, "removing"},
		{"provisioning no host", cloudclient.Barkpark{Host: ""}, "provisioning"},
		{"provisioning with in-flight provision", cloudclient.Barkpark{Host: "", ProvisionStatus: "claimed"}, "provisioning"},
		{"ok", live(cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online", UpdateState: "current"}), "ok"},
		{"ok with empty update_state", live(cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online"}), "ok"},

		// --- D69: the three rungs this slice lands ---
		{"unreported: live but never heard from",
			cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online"}, "unreported"},
		{"unreported outranks the cached health columns (console precedence)",
			cloudclient.Barkpark{Host: "h", HealthStatus: "unknown", AgentStatus: "offline"}, "unreported"},
		{"unreported is a LIVE-box state: a removing box is still removing",
			cloudclient.Barkpark{Host: "h", DeprovisionStatus: "pending"}, "removing"},
		{"strained: load15 2.1x on 2 cores",
			pressed("s", &cloudclient.Pressure{CPUCores: f64(2), Load15: f64(4.2), ReportedAt: strPtr(seen)}), "strained"},
		{"filling: disk at the meter's own ceiling",
			pressed("f", &cloudclient.Pressure{CPUCores: f64(4), Load15: f64(0.4), DiskUsedPercent: f64(95), ReportedAt: strPtr(seen)}), "filling"},
		{"strained beats filling",
			pressed("sf", &cloudclient.Pressure{CPUCores: f64(2), Load15: f64(4.2), DiskUsedPercent: f64(99), ReportedAt: strPtr(seen)}), "strained"},
		{"degraded beats strained",
			cloudclient.Barkpark{Host: "h", LastSeenAt: seen, HealthStatus: "down", AgentStatus: "online",
				Pressure: &cloudclient.Pressure{CPUCores: f64(2), Load15: f64(9), ReportedAt: strPtr(seen)}}, "degraded"},
		{"strained beats behind",
			cloudclient.Barkpark{Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online", UpdateState: "behind",
				Pressure: &cloudclient.Pressure{CPUCores: f64(2), Load15: f64(4.2), ReportedAt: strPtr(seen)}}, "strained"},
		{"filling beats behind",
			cloudclient.Barkpark{Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online", UpdateState: "behind",
				Pressure: &cloudclient.Pressure{DiskUsedPercent: f64(90), ReportedAt: strPtr(seen)}}, "filling"},
		{"an all-nil pressure block never strains and never fills",
			pressed("nil", &cloudclient.Pressure{ReportedAt: strPtr(seen)}), "ok"},
	}
	for _, c := range cases {
		if got := attentionStatus(c.bp); got != c.want {
			t.Errorf("%s: attentionStatus = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestAttentionBucket pins EVERY one of the eleven D69 states to its bucket.
// Its job is to prove the bucket boundary MOVED CORRECTLY: the three new rungs
// land in attention, and — the part that actually flips — every pre-existing
// state keeps the bucket it shipped with. `behind` (rank 5 → 8) staying in
// ATTENTION is the assertion that the shorter boundaries D56 first proposed
// (<=6, <=7) fail on; `removing`/`provisioning` staying in-flight and `ok`
// staying healthy are the assertions a too-LONG boundary fails on.
func TestAttentionBucket(t *testing.T) {
	cases := map[string]string{
		"removal_failed": "attention", "failed": "attention", "suspended": "attention",
		"degraded": "attention",
		// the D69 additions
		"strained": "attention", "filling": "attention", "unreported": "attention",
		// the jpf-w1 D7 addition — a stalled queue is a thing to LOOK AT
		"deploy_stalled": "attention",
		// unchanged from the shipped ladder — the drift tripwire
		"behind":   "attention",
		"removing": "in-flight", "provisioning": "in-flight",
		"ok": "healthy",
	}
	if len(cases) != len(attentionRankOrder) {
		t.Fatalf("bucket table covers %d states, the ladder has %d", len(cases), len(attentionRankOrder))
	}
	for status, want := range cases {
		if got := attentionBucket(status); got != want {
			t.Errorf("attentionBucket(%q) = %q, want %q", status, got, want)
		}
	}
	// An unranked/unknown state must NEVER reach healthy: a half-landed rung
	// bucketing a strained box HEALTHY is the exact inversion this epic kills.
	if got := attentionBucket("some_future_rung"); got != "attention" {
		t.Errorf("unknown state bucketed %q, want attention", got)
	}
}

// TestAttentionLadderIsTwelveRungs pins the ladder itself — order and length —
// so a rung inserted at the wrong height (which silently re-buckets its
// neighbours) fails here rather than in an operator's terminal.
func TestAttentionLadderIsTwelveRungs(t *testing.T) {
	want := []string{
		"removal_failed", "failed", "suspended", "degraded",
		"strained", "filling", "unreported", "deploy_stalled", "behind",
		"removing", "provisioning", "ok",
	}
	if len(attentionRankOrder) != len(want) {
		t.Fatalf("ladder has %d rungs, want %d: %v", len(attentionRankOrder), len(want), attentionRankOrder)
	}
	for i := range want {
		if attentionRankOrder[i] != want[i] {
			t.Fatalf("ladder = %v, want %v", attentionRankOrder, want)
		}
	}
	// The bucket boundaries, stated as ranks — the numbers a reviewer checks.
	for _, c := range []struct {
		state  string
		rank   int
		bucket string
	}{
		{"removal_failed", 1, "attention"},
		{"deploy_stalled", 8, "attention"}, // jpf-w1 D7: after unreported, before behind
		{"behind", 9, "attention"},         // the LAST attention rung
		{"removing", 10, "in-flight"},
		{"provisioning", 11, "in-flight"},
		{"ok", 12, "healthy"}, // the ONLY healthy rung
	} {
		if got := attentionRank(c.state); got != c.rank {
			t.Errorf("attentionRank(%q) = %d, want %d", c.state, got, c.rank)
		}
		if got := attentionBucket(c.state); got != c.bucket {
			t.Errorf("attentionBucket(%q) = %q, want %q", c.state, got, c.bucket)
		}
	}
}

// TestDeployStalledFence is the jpf-w1 D6/D7 fence table. The three honest-
// silence shapes can NEVER stall — nil is both "nothing queued" and "a CP that
// predates the field" — and the boundary is >= 300, not > 300. The nil arm is
// the alarm's fail-closed contract stated positively: with no queued-age input
// the alarm says NOTHING, it does not scan an empty corpus and report calm.
func TestDeployStalledFence(t *testing.T) {
	age := func(v float64) *float64 { return &v }
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want bool
	}{
		{"no field (older CP / nothing queued)", cloudclient.Barkpark{}, false},
		{"fresh queue, under the fence", cloudclient.Barkpark{QueuedDeployAgeSeconds: age(299)}, false},
		{"exactly the fence", cloudclient.Barkpark{QueuedDeployAgeSeconds: age(300)}, true},
		{"the incident shape: 7.5h unclaimed", cloudclient.Barkpark{QueuedDeployAgeSeconds: age(27000)}, true},
	}
	for _, c := range cases {
		if got := deployStalled(c.bp); got != c.want {
			t.Errorf("%s: deployStalled = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestDeployStalledStatusAndDetail drives the full classification: a live,
// healthy, current box whose only fault is a 7-minute unclaimed queued deploy
// must read deploy_stalled, land in ATTENTION, and NAME THE AGE in its detail
// — and the same box with a fresh queue (or none) must read ok with an empty
// detail, so the assertion has a side that can fail.
func TestDeployStalledStatusAndDetail(t *testing.T) {
	age := func(v float64) *float64 { return &v }
	base := cloudclient.Barkpark{
		Host: "10.0.0.9", LastSeenAt: "2026-08-06T12:00:00Z",
		HealthStatus: "up", AgentStatus: "online", UpdateState: "current",
	}

	stalled := base
	stalled.QueuedDeployAgeSeconds = age(420)
	if st := attentionStatus(stalled); st != "deploy_stalled" {
		t.Fatalf("status = %q, want deploy_stalled", st)
	}
	if b := attentionBucket("deploy_stalled"); b != "attention" {
		t.Fatalf("bucket = %q, want attention", b)
	}
	d := attentionDetail(stalled, "deploy_stalled")
	if want := "deploy queued 7m — no builder claimed it"; d != want {
		t.Fatalf("detail = %q, want %q", d, want)
	}

	// A DEGRADED box with the same stalled queue stays degraded: the stuck
	// queue is a symptom and the box's own condition outranks it (D7).
	degraded := stalled
	degraded.AgentStatus = "offline"
	if st := attentionStatus(degraded); st != "degraded" {
		t.Fatalf("degraded+stalled = %q, want degraded (the box outranks its queue)", st)
	}

	// Fresh queue → ok, and the detail stays honestly empty.
	fresh := base
	fresh.QueuedDeployAgeSeconds = age(60)
	if st := attentionStatus(fresh); st != "ok" {
		t.Fatalf("fresh-queue status = %q, want ok", st)
	}
	if d := attentionDetail(fresh, "ok"); d != "" {
		t.Fatalf("fresh-queue detail = %q, want empty", d)
	}
	if r := deployStalledReason(fresh); r != "" {
		t.Fatalf("deployStalledReason under the fence = %q — it may never assert a stall it did not measure", r)
	}
}

// TestStrainedFence is the D67 fence table: the four measured shapes (load15
// over/under, load15 absent with load1 over/under) plus the three HONEST-SILENCE
// shapes, which must NEVER strain — an unmeasured vital reads "we did not
// measure", never "measured, and it is fine" (D42's factual arm).
func TestStrainedFence(t *testing.T) {
	cases := []struct {
		name string
		p    *cloudclient.Pressure
		want bool
	}{
		{"load15 over the fence (4.2/2 = 2.1x >= 1.75)",
			&cloudclient.Pressure{CPUCores: f64(2), Load15: f64(4.2), Load1: f64(0.1)}, true},
		{"load15 exactly at the fence (3.5/2 = 1.75x)",
			&cloudclient.Pressure{CPUCores: f64(2), Load15: f64(3.5)}, true},
		{"load15 under the fence (3.4/2 = 1.7x)",
			&cloudclient.Pressure{CPUCores: f64(2), Load15: f64(3.4), Load1: f64(99)}, false},
		{"load15 absent, load1 over the higher fallback fence (4.2/2 = 2.1x >= 2.0)",
			&cloudclient.Pressure{CPUCores: f64(2), Load1: f64(4.2)}, true},
		{"load15 absent, load1 between the two fences (3.8/2 = 1.9x) — the fallback UNDER-reports on purpose",
			&cloudclient.Pressure{CPUCores: f64(2), Load1: f64(3.8)}, false},
		// --- honest silence ---
		{"cpu_cores nil: no denominator, never strained",
			&cloudclient.Pressure{Load15: f64(99), Load1: f64(99)}, false},
		{"both loads nil: nothing to judge",
			&cloudclient.Pressure{CPUCores: f64(2)}, false},
		{"whole pressure block absent (an older control plane)", nil, false},
	}
	for _, c := range cases {
		bp := pressed("x", c.p)
		if got := strained(bp); got != c.want {
			t.Errorf("%s: strained = %v, want %v", c.name, got, c.want)
		}
		// And the fence must reach the LADDER, not just the predicate.
		wantStatus := "ok"
		if c.want {
			wantStatus = "strained"
		}
		if got := attentionStatus(bp); got != wantStatus {
			t.Errorf("%s: attentionStatus = %q, want %q", c.name, got, wantStatus)
		}
	}
	// A zero core count is a garbage denominator, not a measurement.
	if strained(pressed("z", &cloudclient.Pressure{CPUCores: f64(0), Load15: f64(9)})) {
		t.Error("cpu_cores 0 must never strain (division by a fabricated denominator)")
	}
}

// TestFillingFence pins the disk rung, including the boundary and the silence.
func TestFillingFence(t *testing.T) {
	cases := []struct {
		name string
		p    *cloudclient.Pressure
		want bool
	}{
		{"95% — jarl today", &cloudclient.Pressure{DiskUsedPercent: f64(95)}, true},
		{"exactly 90%", &cloudclient.Pressure{DiskUsedPercent: f64(90)}, true},
		{"89.9%", &cloudclient.Pressure{DiskUsedPercent: f64(89.9)}, false},
		{"unmeasured disk is never filling", &cloudclient.Pressure{CPUCores: f64(2)}, false},
		{"no pressure block at all", nil, false},
	}
	for _, c := range cases {
		if got := filling(pressed("x", c.p)); got != c.want {
			t.Errorf("%s: filling = %v, want %v", c.name, got, c.want)
		}
	}
}

// TestTheBuildPlaneBoxDoesNotRankHealthy asserts the VERDICT, not a predicate,
// for the box this whole axis is named after — measured twice, live:
//
//	2026-08-06  df -P -k /  →  38G total, 34G used, 1.8G free, 96%
//	2026-08-22  df -P -k /  →  37G total, 36G used, 285M free, 100%
//
// "Does the box rank correctly" is exactly where a green about the wrong
// subject gets believed, so this asserts the two things an operator actually
// reads — the BUCKET and the LABEL — and fails if either says the machine is
// fine. It deliberately duplicates coverage TestFillingFence already has at
// 95%: this one is pinned to real readings off a real host, so a future rung
// re-ordering that happens to spare 95% cannot quietly re-heal 96 or 100.
func TestTheBuildPlaneBoxDoesNotRankHealthy(t *testing.T) {
	for _, pct := range []float64{96, 100} {
		box := pressed("build-plane", &cloudclient.Pressure{
			CPUCores: f64(2), Load15: f64(0.4),
			DiskUsedPercent: f64(pct), ReportedAt: strPtr(seen),
		})
		status := attentionStatus(box)
		if bucket := attentionBucket(status); bucket == "healthy" {
			t.Errorf("a box at %v%% disk ranked %q/%q — a verdict that says \"fine\" about a "+
				"machine with under 2 GB of headroom is worse than no verdict, because the "+
				"operator reads it and looks somewhere else", pct, status, bucket)
		}
		if status != "filling" {
			t.Errorf("a box at %v%% disk ranked %q, want \"filling\"", pct, status)
		}
		if reason := fillingReason(box); !strings.Contains(reason, "fills at 90") {
			t.Errorf("fillingReason = %q, want the fence NAMED so the number is not a bare assertion", reason)
		}
	}
}

// TestFillingThresholdMatchesUsageMeter is the cross-surface tripwire the rung
// exists for: `bp cloud status` must call a box `filling` at exactly the disk
// percentage `bp cloud usage` already calls over_limit. It reads the LIVE
// Elixir source rather than a copied constant, so moving one number without the
// other reds here — the failure mode being killed is a status view that says
// HEALTHY about a box the meter view is calling over_limit.
func TestFillingThresholdMatchesUsageMeter(t *testing.T) {
	usagePath := filepath.Join("..", "..", "cloud", "lib", "barkpark_cloud", "usage.ex")
	raw, err := os.ReadFile(usagePath)
	if err != nil {
		t.Fatalf("read usage.ex: %v", err)
	}
	// The shipped line: meter(value, @src_disk, measured_at, 100, 70, 90)
	re := regexp.MustCompile(`meter\(\s*value,\s*@src_disk,[^)]*?,\s*([0-9.]+)\s*\)`)
	m := re.FindSubmatch(raw)
	if m == nil {
		t.Fatalf("could not find the @src_disk meter call in %s — if it moved, this tripwire must be re-aimed, not deleted", usagePath)
	}
	got, err := strconv.ParseFloat(string(m[1]), 64)
	if err != nil {
		t.Fatalf("parse the usage.ex disk ceiling %q: %v", m[1], err)
	}
	if got != fillingDiskPercent {
		t.Fatalf("usage.ex ships an over_limit disk ceiling of %v but fillingDiskPercent is %v — the verdict surface and the meter surface have drifted", got, fillingDiskPercent)
	}
}

// TestStrainedReasonSaysLoadNotCPU: the reason must name LOAD (load1/load15
// count uninterruptible sleep, so an I/O-stalled box is honestly under load
// while its CPU is idle), must name WHICH average it used, and must never say
// "CPU" in any casing. Swap ENRICHES it and can never produce it.
func TestStrainedReasonSaysLoadNotCPU(t *testing.T) {
	withSwap := pressed("guerrilla-like", &cloudclient.Pressure{
		CPUPercent: f64(41), CPUCores: f64(2), Load15: f64(4.9), Load1: f64(5.1),
		SwapUsedPercent: f64(100), SwapTotalBytes: f64(1073741824),
		ReportedAt: strPtr(seen),
	})
	noSwap := pressed("no-swap", &cloudclient.Pressure{
		CPUCores: f64(2), Load15: f64(4.9), ReportedAt: strPtr(seen),
	})
	fallback := pressed("old-agent", &cloudclient.Pressure{
		CPUCores: f64(2), Load1: f64(4.9), ReportedAt: strPtr(seen),
	})

	for _, c := range []struct {
		name string
		bp   cloudclient.Barkpark
		want []string
	}{
		{"15m with swap", withSwap, []string{"load 4.9", "2 cores", "2.5x", "15m avg", "1.0 GB in swap"}},
		{"15m without swap", noSwap, []string{"load 4.9", "2 cores", "2.5x", "15m avg"}},
		{"1m fallback names its window", fallback, []string{"load 4.9", "1m avg"}},
	} {
		got := strainedReason(c.bp)
		for _, want := range c.want {
			if !strings.Contains(got, want) {
				t.Errorf("%s: reason %q missing %q", c.name, got, want)
			}
		}
		if strings.Contains(strings.ToLower(got), "cpu") {
			t.Errorf("%s: reason must never say CPU (load counts I/O wait): %q", c.name, got)
		}
		if strings.Contains(got, "swap") && c.name == "15m without swap" {
			t.Errorf("%s: a box that reported no swap must not claim any: %q", c.name, got)
		}
	}
	// Swap alone can NEVER strain: a box paging hard at a calm load stays ok.
	swampedButCalm := pressed("calm", &cloudclient.Pressure{
		CPUCores: f64(4), Load15: f64(0.2),
		SwapUsedPercent: f64(99), SwapTotalBytes: f64(4294967296), ReportedAt: strPtr(seen),
	})
	if got := attentionStatus(swampedButCalm); got != "ok" {
		t.Errorf("swap must enrich, never trigger: got %q, want ok", got)
	}
}

// TestUnmeteredMarker: a box that IS beating (fresh reported_at) but reports a
// null cpu_cores is running an agent that predates the vitals beat. That is a
// fact about the READING, not the verdict, so it rides as a detail line on the
// row it already had — never as a rung, and never silently as an ordinary
// healthy row.
func TestUnmeteredMarker(t *testing.T) {
	// The shape five of six live boxes are in today: beating, unreadable.
	stale := pressed("jarl-like", &cloudclient.Pressure{ReportedAt: strPtr(seen)})
	if got := attentionStatus(stale); got != "ok" {
		t.Fatalf("the marker must not invent a rung: status = %q, want ok", got)
	}
	detail := attentionDetail(stale, attentionStatus(stale))
	if !strings.Contains(detail, "vitals unreadable") {
		t.Fatalf("a beating-but-unreadable box must SAY so: detail = %q", detail)
	}

	// A box that has never beaten at all is `unreported` — a different fact, and
	// the marker must not double up on it.
	never := cloudclient.Barkpark{Host: "h", HealthStatus: "up", AgentStatus: "online",
		Pressure: &cloudclient.Pressure{}}
	if got := attentionStatus(never); got != "unreported" {
		t.Fatalf("never-beaten box = %q, want unreported", got)
	}
	if d := attentionDetail(never, "unreported"); d != "" {
		t.Fatalf("no marker for a box that never beat: %q", d)
	}

	// A readable box carries no marker at all.
	readable := pressed("readable", &cloudclient.Pressure{
		CPUCores: f64(2), Load15: f64(0.2), DiskUsedPercent: f64(30), ReportedAt: strPtr(seen)})
	if d := attentionDetail(readable, "ok"); d != "" {
		t.Fatalf("a readable box must carry no marker: %q", d)
	}

	// The marker COMPOSES with a real reason rather than replacing it: a filling
	// box whose loads are unreadable says both.
	half := pressed("half", &cloudclient.Pressure{DiskUsedPercent: f64(95), ReportedAt: strPtr(seen)})
	d := attentionDetail(half, attentionStatus(half))
	if !strings.Contains(d, "disk 95% used") || !strings.Contains(d, "vitals unreadable") {
		t.Fatalf("detail should carry BOTH the reason and the marker: %q", d)
	}
}

// attentionVocabularyFixturePath is the decision-32 cross-surface status
// vocabulary — the SAME file the node harness asserts statusOf/statusMeta
// against (from wave 3), read here relative to internal/cli/ exactly like the
// hetzner_overview.json golden.
var attentionVocabularyFixturePath = filepath.Join("..", "..", "cloud", "priv", "static", "__fixtures__", "attention_order.json")

// TestAttentionVocabularyMatchesFixture holds the Go implementation to the
// committed decision-32 fixture: every state, in fixture order, must carry the
// pinned rank (attentionRank), bucket (attentionBucket) and tone (statusRole),
// and the state set must be exactly attentionRankOrder. A drift on either side
// — code or fixture — fails here, not in production.
func TestAttentionVocabularyMatchesFixture(t *testing.T) {
	raw, err := os.ReadFile(attentionVocabularyFixturePath)
	if err != nil {
		t.Fatalf("read decision-32 fixture: %v", err)
	}
	var f struct {
		States []struct {
			State  string `json:"state"`
			Rank   int    `json:"rank"`
			Bucket string `json:"bucket"`
			Tone   string `json:"tone"`
			Glyph  string `json:"glyph"`
			Label  string `json:"label"`
		} `json:"states"`
	}
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode decision-32 fixture: %v", err)
	}
	if len(f.States) != len(attentionRankOrder) {
		t.Fatalf("fixture has %d states, code has %d", len(f.States), len(attentionRankOrder))
	}
	for i, s := range f.States {
		if s.State != attentionRankOrder[i] {
			t.Errorf("state %d: fixture %q, code %q", i, s.State, attentionRankOrder[i])
		}
		if got := attentionRank(s.State); got != s.Rank {
			t.Errorf("%s: attentionRank = %d, fixture rank %d", s.State, got, s.Rank)
		}
		if got := attentionBucket(s.State); got != s.Bucket {
			t.Errorf("%s: attentionBucket = %q, fixture bucket %q", s.State, got, s.Bucket)
		}
		// THE TONE HOLE, closed. Until this line, a state nobody taught
		// semrole.For about compared "" == "" and PASSED — so a new rung could
		// ship uncoloured, indistinguishable in a terminal from an ok row,
		// while every other assertion here stayed green. Requiring a non-empty
		// fixture tone first means the equality below is now an assertion about
		// a real colour, and blanking any tone in the fixture reds this test.
		if s.Tone == "" {
			t.Errorf("%s: fixture tone must be a real semantic role (ok/info/warn/danger), not empty — an uncoloured status ships invisible", s.State)
		}
		if got := statusRole(s.State); got != s.Tone {
			t.Errorf("%s: statusRole = %q, fixture tone %q", s.State, got, s.Tone)
		}
		if s.Glyph == "" || s.Label == "" {
			t.Errorf("%s: fixture glyph/label must be non-empty (%q/%q)", s.State, s.Glyph, s.Label)
		}
	}
}

// attentionFixture is the shape of testdata/attention_order_cases.json — the
// concrete input→order test companion of the decision-32 vocabulary fixture.
type attentionFixture struct {
	Barkparks     []cloudclient.Barkpark `json:"barkparks"`
	ExpectedOrder []string               `json:"expected_order"`
}

func loadAttentionFixture(t *testing.T) attentionFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "attention_order_cases.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f attentionFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(f.Barkparks) != len(f.ExpectedOrder) {
		t.Fatalf("fixture has %d barkparks but %d expected names", len(f.Barkparks), len(f.ExpectedOrder))
	}
	return f
}

// TestRankBarkparksFixture is the contract assertion: rankBarkparks reproduces
// the committed fixture's expected order EXACTLY — every rank + the
// case-insensitive name tiebreak (alpha < ok-1 < Zeta within the ok bucket).
func TestRankBarkparksFixture(t *testing.T) {
	f := loadAttentionFixture(t)
	ranked := rankBarkparks(f.Barkparks)
	got := make([]string, len(ranked))
	for i, r := range ranked {
		got[i] = r.BP.Name
	}
	if len(got) != len(f.ExpectedOrder) {
		t.Fatalf("ranked %d rows, expected %d", len(got), len(f.ExpectedOrder))
	}
	for i := range got {
		if got[i] != f.ExpectedOrder[i] {
			t.Fatalf("rank order mismatch at %d:\n got: %v\nwant: %v", i, got, f.ExpectedOrder)
		}
	}
}

// TestRankBarkparksTiebreakCaseInsensitive isolates the tiebreak: two same-rank
// boxes whose only difference is case sort case-insensitively (ASCII-sensitive
// order would put "Zebra" before "apple").
func TestRankBarkparksTiebreakCaseInsensitive(t *testing.T) {
	ok := func(id, name string) cloudclient.Barkpark {
		return cloudclient.Barkpark{ID: id, Name: name, Host: "h", HealthStatus: "up", AgentStatus: "online"}
	}
	ranked := rankBarkparks([]cloudclient.Barkpark{ok("2", "Zebra"), ok("1", "apple")})
	if ranked[0].BP.Name != "apple" || ranked[1].BP.Name != "Zebra" {
		t.Fatalf("case-insensitive tiebreak failed: %s then %s", ranked[0].BP.Name, ranked[1].BP.Name)
	}
}

// TestRunCloudStatusJSON drives the whole command against a fake control plane
// and asserts the ranked, bucketed -o json structure.
func TestRunCloudStatusJSON(t *testing.T) {
	withTempConfigHome(t)

	// dr-w19-s7 followup: the json path reads the census + site list too, so
	// this fake records EVERY path hit and the assertion below checks
	// /v1/barkparks was among them — not that it was hit LAST, which is the pin
	// that used to make adding the reads impossible.
	var gotPaths []string
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPaths, gotAuth = append(gotPaths, r.URL.Path), r.Header.Get("Authorization")
		switch r.URL.Path {
		case "/v1/deploy-ledger/census":
			_, _ = io.WriteString(w, `{"volume":0,"failed":0,"failure_rate":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"sample 0 below min_sample 200"},"classes":[],"not_attempted":[],"sites":[],"min_sample":200}`)
			return
		case "/v1/sites":
			_, _ = io.WriteString(w, `{"sites":[]}`)
			return
		}
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"a","name":"ok-box","host":"h","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online","update_state":"current",
			 "pressure":{"cpu_percent":4,"cpu_cores":4,"mem_used_percent":22,"load1":0.2,"load15":0.1,"disk_used_percent":31,"swap_used_percent":null,"swap_total_bytes":null,"beam_pss_bytes":null,"beam_swap_bytes":null,"err_5xx_per_s":null,"reported_at":"2026-08-06T12:00:00Z"}},
			{"id":"b","name":"dead-box","host":"","provision_status":"failed","provision_error":"cloud-init timed out"},
			{"id":"c","name":"slow-box","host":"h","last_seen_at":"2026-08-06T12:00:00Z","health_status":"unknown","agent_status":"online"},
			{"id":"d","name":"hot-box","host":"h","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online",
			 "pressure":{"cpu_percent":41,"cpu_cores":2,"mem_used_percent":88,"load1":5.1,"load15":4.2,"disk_used_percent":62,"swap_used_percent":92.9,"swap_total_bytes":1073741824,"beam_pss_bytes":null,"beam_swap_bytes":null,"err_5xx_per_s":null,"reported_at":"2026-08-06T12:00:00Z"}},
			{"id":"e","name":"full-box","host":"h","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online",
			 "pressure":{"cpu_percent":6,"cpu_cores":4,"mem_used_percent":31,"load1":0.9,"load15":0.8,"disk_used_percent":95,"swap_used_percent":null,"swap_total_bytes":null,"beam_pss_bytes":null,"beam_swap_bytes":null,"err_5xx_per_s":null,"reported_at":"2026-08-06T12:00:00Z"}}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	hitFleet := false
	for _, p := range gotPaths {
		if p == "/v1/barkparks" {
			hitFleet = true
		}
	}
	if !hitFleet {
		t.Fatalf("hit %v, want /v1/barkparks among them", gotPaths)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}

	var resp struct {
		OK      bool `json:"ok"`
		Count   int  `json:"count"`
		Buckets struct {
			Attention int `json:"attention"`
			InFlight  int `json:"in-flight"` // decision-32 bucket spelling
			Healthy   int `json:"healthy"`
		} `json:"buckets"`
		Deploy struct {
			State  string `json:"state"`
			Window struct {
				From string `json:"from"`
				To   string `json:"to"`
			} `json:"window"`
		} `json:"deploy"`
		Barkparks []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Bucket string `json:"bucket"`
			Rank   int    `json:"rank"`
			Detail string `json:"detail"`
			Deploy struct {
				State string `json:"state"`
			} `json:"deploy"`
		} `json:"barkparks"`
	}
	if err := json.Unmarshal([]byte(stdout), &resp); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	if !resp.OK || resp.Count != 5 {
		t.Fatalf("ok/count = %v/%d", resp.OK, resp.Count)
	}
	// THE HEADLINE: the strained and filling boxes are counted in ATTENTION,
	// not quietly parked in HEALTHY beside the idle one.
	if resp.Buckets.Attention != 4 || resp.Buckets.Healthy != 1 || resp.Buckets.InFlight != 0 {
		t.Fatalf("buckets = %+v", resp.Buckets)
	}
	// Ranked most-urgent-first, ranks 1-based per the decision-32 fixture:
	// failed (2) < degraded (4) < strained (5) < filling (6) < ok (12).
	wantOrder := []string{"dead-box", "slow-box", "hot-box", "full-box", "ok-box"}
	wantStatus := []string{"failed", "degraded", "strained", "filling", "ok"}
	wantRank := []int{2, 4, 5, 6, 12}
	for i := range wantOrder {
		if resp.Barkparks[i].Name != wantOrder[i] || resp.Barkparks[i].Status != wantStatus[i] || resp.Barkparks[i].Rank != wantRank[i] {
			t.Fatalf("row %d = %s/%s/rank %d, want %s/%s/rank %d", i,
				resp.Barkparks[i].Name, resp.Barkparks[i].Status, resp.Barkparks[i].Rank,
				wantOrder[i], wantStatus[i], wantRank[i])
		}
	}
	// The failure reason the control plane sent rides along as detail.
	if resp.Barkparks[0].Detail != "cloud-init timed out" {
		t.Fatalf("dead-box detail = %q, want the provision error", resp.Barkparks[0].Detail)
	}
	if resp.Barkparks[4].Detail != "" {
		t.Fatalf("ok-box detail = %q, want empty", resp.Barkparks[4].Detail)
	}
	// The vitals rows explain themselves off the numbers the CP already sent.
	if d := resp.Barkparks[2].Detail; !strings.Contains(d, "load 4.2") || !strings.Contains(d, "in swap") {
		t.Fatalf("hot-box detail = %q, want the measured load and its swap evidence", d)
	}
	if d := resp.Barkparks[3].Detail; !strings.Contains(d, "disk 95% used") {
		t.Fatalf("full-box detail = %q, want the measured disk reading", d)
	}
	// dr-w19-s7 followup: the deploy node is present at BOTH levels. This
	// census was read and carried no site rows, so every box is "no_rows" — a
	// measured empty window, not an omitted key.
	if resp.Deploy.State != "read" || resp.Deploy.Window.From == "" || resp.Deploy.Window.To == "" {
		t.Fatalf("fleet deploy node = %+v, want state read with a pinned window", resp.Deploy)
	}
	for i, b := range resp.Barkparks {
		if b.Deploy.State != "no_rows" {
			t.Fatalf("row %d deploy.state = %q, want no_rows", i, b.Deploy.State)
		}
	}
}

// TestRunCloudStatusNoToken: without a Cloud token the command is an auth error
// with a `bp login` hint, and makes no network call.
func TestRunCloudStatusNoToken(t *testing.T) {
	withTempConfigHome(t)
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // human path: the hint lands on stderr
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !bytes.Contains([]byte(stderr), []byte("bp login")) {
		t.Fatalf("expected a login hint on stderr:\n%s", stderr)
	}
}

// TestRunCloudStatusEmptyFleet: a logged-in user with no Barkparks gets a clean
// guiding line, not an empty table.
func TestRunCloudStatusEmptyFleet(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !bytes.Contains([]byte(stdout), []byte("no Barkparks yet")) {
		t.Fatalf("expected empty-fleet guidance:\n%s", stdout)
	}
}

// TestRunCloudStatusTableDetailColumn: the human table carries the control
// plane's own failure reason as a DETAIL column — but only in buckets where at
// least one row has one (the healthy bucket never grows the column).
func TestRunCloudStatusTableDetailColumn(t *testing.T) {
	withTempConfigHome(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"a","name":"ok-box","host":"h","url":"https://ok.example","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online"},
			{"id":"b","name":"dead-box","host":"","provision_status":"failed","provision_error":"cloud-init timed out"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	lines := strings.Split(stdout, "\n")
	attentionHeader, healthyHeader := "", ""
	for i, l := range lines {
		if strings.HasPrefix(l, "ATTENTION") && i+1 < len(lines) {
			attentionHeader = lines[i+1]
		}
		if strings.HasPrefix(l, "HEALTHY") && i+1 < len(lines) {
			healthyHeader = lines[i+1]
		}
	}
	if !strings.Contains(attentionHeader, "DETAIL") {
		t.Fatalf("attention bucket should carry a DETAIL column:\n%s", stdout)
	}
	if !strings.Contains(stdout, "cloud-init timed out") {
		t.Fatalf("the provision error should be visible:\n%s", stdout)
	}
	if strings.Contains(healthyHeader, "DETAIL") {
		t.Fatalf("healthy bucket must not grow a DETAIL column:\n%s", stdout)
	}
}

// --- the DEPLOY section (dr-w19-s7) ------------------------------------------

// statusDeployFleet is the fleet body every deploy-section test renders: two
// live, healthy boxes. Both read `ok` on every column above the DEPLOY section,
// which is the whole point — the deploy line is the sentence those columns
// cannot say.
const statusDeployFleet = `{"barkparks":[
	{"id":"bp-1","name":"alpha","host":"h1","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online","update_state":"current"},
	{"id":"bp-2","name":"beta","host":"h2","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online","update_state":"current"}
]}`

// statusDeploySites maps the census's site_ids onto boxes — the fold `bp cloud
// status` does client-side, because a census row carries site_id and nothing
// that names a box.
const statusDeploySites = `{"sites":[
	{"id":"site-a","barkpark_id":"bp-1"},
	{"id":"site-c","barkpark_id":"bp-2"}
]}`

// newStatusDeployServer stands up a fake control plane answering the three
// routes the DEPLOY section reads, with a chosen census status + body.
func newStatusDeployServer(t *testing.T, censusStatus int, censusBody string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/deploy-ledger/census":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(censusStatus)
			_, _ = io.WriteString(w, censusBody)
		case "/v1/sites":
			_, _ = io.WriteString(w, statusDeploySites)
		default:
			_, _ = io.WriteString(w, statusDeployFleet)
		}
	}))
	t.Cleanup(srv.Close)
	seedCloudLogin(t, srv.URL)
}

// statusDeployCensus builds a census body whose two site rows carry the given
// volume/live. `live` is a real key here; the older-control-plane case has its
// own body below, WITHOUT it.
func statusDeployCensus(minSample, aVolume, aLive, cVolume, cLive int) string {
	return fmt.Sprintf(`{"window":{"from":"2026-08-07T00:00:00Z","to":"2026-08-08T00:00:00Z"},
		"volume":%d,"failed":0,"min_sample":%d,
		"failure_rate":{"sample":%d,"pct":0,"numerator":0,"min_sample":%d,"refused":false,"reason":""},
		"sites":[
			{"site_id":"site-a","volume":%d,"failed":1,"deferred":0,"live":%d,"failure_rate":{"sample":%d,"pct":null,"numerator":1,"min_sample":%d,"refused":true,"reason":""},"top_class":null},
			{"site_id":"site-c","volume":%d,"failed":0,"deferred":0,"live":%d,"failure_rate":{"sample":%d,"pct":null,"numerator":0,"min_sample":%d,"refused":true,"reason":""},"top_class":null}
		]}`,
		aVolume+cVolume, minSample, aVolume+cVolume, minSample,
		aVolume, aLive, aVolume, minSample,
		cVolume, cLive, cVolume, minSample)
}

// statusDeployLineFor returns the DEPLOY line for a named box.
func statusDeployLineFor(t *testing.T, out, name string) string {
	t.Helper()
	for _, l := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(l)
		if strings.HasPrefix(trimmed, name+" ") && !strings.Contains(l, "https://") {
			return trimmed
		}
	}
	t.Fatalf("no DEPLOY line for %q:\n%s", name, out)
	return ""
}

// TestStatusDeployLineCarriesLiveRateWithItsDenominator is the headline pin: a
// metered box prints live WITH the denominator it was taken over, under a window
// that names its DAILY period — and nothing above it moves.
func TestStatusDeployLineCarriesLiveRateWithItsDenominator(t *testing.T) {
	withTempConfigHome(t)
	newStatusDeployServer(t, 200, statusDeployCensus(200, 435, 109, 1479, 416))

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "DEPLOY · period: DAILY · window") {
		t.Fatalf("the deploy section must name its DAILY period and its window:\n%s", stdout)
	}
	// alpha owns site-a (435/109); beta owns site-c (1479/416). Both clear
	// min_sample 200, so both are a rate WITH its denominator.
	if line := statusDeployLineFor(t, stdout, "alpha"); !strings.Contains(line, "live 109/435 (25.1%)") {
		t.Fatalf("alpha deploy line = %q, want the rate WITH its denominator", line)
	}
	if line := statusDeployLineFor(t, stdout, "beta"); !strings.Contains(line, "live 416/1479 (28.1%)") {
		t.Fatalf("beta deploy line = %q, want the rate WITH its denominator", line)
	}
	// Both boxes still read `ok`: the gauge changed no status, rank or bucket.
	if !strings.Contains(stdout, "HEALTHY (2)") {
		t.Fatalf("the deploy line must not move a box between buckets:\n%s", stdout)
	}
}

// TestStatusDeployRefusesBelowMinSample: under the census's own @min_sample the
// line is UNMETERED with the reason — never a percentage, never a comforting
// zero, and never a green.
func TestStatusDeployRefusesBelowMinSample(t *testing.T) {
	withTempConfigHome(t)
	newStatusDeployServer(t, 200, statusDeployCensus(200, 12, 0, 4, 4))

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	line := statusDeployLineFor(t, stdout, "alpha")
	if !strings.Contains(line, "UNMETERED") || !strings.Contains(line, "min_sample of 200") {
		t.Fatalf("alpha deploy line = %q, want UNMETERED naming the floor", line)
	}
	if strings.Contains(line, "%)") {
		t.Fatalf("a refused line must carry no percentage: %q", line)
	}
	// The box that shipped 4 of 4 is refused too — a flattering small sample is
	// as unmeasured as a damning one.
	if l := statusDeployLineFor(t, stdout, "beta"); !strings.Contains(l, "UNMETERED") {
		t.Fatalf("beta deploy line = %q, want UNMETERED on a 4-row sample", l)
	}
}

// TestStatusDeployOlderControlPlaneIsUnmeteredNotZeroLive is the POINTER pin: a
// control plane predating #10519 sends site rows with no `live` key at all, and
// that must render UNMETERED — a nil summed as zero would report every box in
// the fleet as shipping nothing, the most alarming reading of an absence there
// is.
func TestStatusDeployOlderControlPlaneIsUnmeteredNotZeroLive(t *testing.T) {
	withTempConfigHome(t)
	const noLive = `{"window":{"from":"2026-08-07T00:00:00Z","to":"2026-08-08T00:00:00Z"},
		"volume":1914,"failed":18,"min_sample":200,
		"failure_rate":{"sample":1914,"pct":0.9,"numerator":18,"min_sample":200,"refused":false,"reason":""},
		"sites":[
			{"site_id":"site-a","volume":435,"failed":1,"deferred":325,"failure_rate":{"sample":435,"pct":0.2,"numerator":1,"min_sample":200,"refused":false,"reason":""},"top_class":null},
			{"site_id":"site-c","volume":1479,"failed":17,"deferred":900,"failure_rate":{"sample":1479,"pct":1.1,"numerator":17,"min_sample":200,"refused":false,"reason":""},"top_class":null}
		]}`
	newStatusDeployServer(t, 200, noLive)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	line := statusDeployLineFor(t, stdout, "alpha")
	if !strings.Contains(line, "UNMETERED") || !strings.Contains(line, "no per-site `live`") {
		t.Fatalf("alpha deploy line = %q, want UNMETERED naming the missing per-site live", line)
	}
	if strings.Contains(line, "live 0/") || strings.Contains(line, "(0.0%)") {
		t.Fatalf("an absent `live` must never render as zero-live: %q", line)
	}
}

// TestStatusDeployCensusRefusalNamesItself: a 403 on the census renders as a
// refusal that says nothing was read — never as a fleet with no deploy rows.
func TestStatusDeployCensusRefusalNamesItself(t *testing.T) {
	withTempConfigHome(t)
	newStatusDeployServer(t, 403, `{"error":"forbidden","scope":"team","required":"read"}`)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the fleet table still rendered)\n%s", code, stdout)
	}
	if !strings.Contains(stdout, "NOT READ") || !strings.Contains(stdout, "403 forbidden") {
		t.Fatalf("a refused census must name the refusal:\n%s", stdout)
	}
	if strings.Contains(stdout, "no deploy rows in this window") {
		t.Fatalf("a refusal must never render as an empty window:\n%s", stdout)
	}
}

// TestStatusDeployIsAGaugeNotAFence: the deploy-census diff added no rung, no
// verdict arm and no hardcoded floor. The ladder is exactly the charter's
// twelve (eleven D69 rungs + jpf-w1 D7's deploy_stalled — the ONE deliberate
// addition, pinned by TestAttentionLadderIsTwelveRungs), the buckets still
// three, and the ONLY threshold the deploy line consults is the census's own
// min_sample off the wire.
func TestStatusDeployIsAGaugeNotAFence(t *testing.T) {
	if len(attentionRankOrder) != 12 {
		t.Fatalf("the ladder grew a rung beyond the charter's twelve: %v", attentionRankOrder)
	}
	// The floor is read, never carried: a census that sends min_sample 999 moves
	// the refusal, which a hardcoded fence could not do.
	metered := &statusDeployBox{Volume: 435, Live: 109, Sites: 1, LiveKnown: true}
	if got := statusDeployLine(metered, 200); !strings.Contains(got, "live 109/435") {
		t.Fatalf("metered = %q", got)
	}
	if got := statusDeployLine(metered, 999); !strings.Contains(got, "UNMETERED") || !strings.Contains(got, "999") {
		t.Fatalf("the floor must come off the wire, got %q", got)
	}
	// And a control plane that sends NO floor cannot be silently assumed to have
	// one: no percentage is quoted at all.
	if got := statusDeployLine(metered, 0); !strings.Contains(got, "UNMETERED") || strings.Contains(got, "%)") {
		t.Fatalf("an absent min_sample must refuse, got %q", got)
	}
}

// TestDeployCensusSiteDecodesLive is the DECODER pin proper: the wire's per-site
// `live` must land in a field. Before this slice DeployCensusSite had six fields
// and no Live, so this key decoded to nothing and nothing said so.
func TestDeployCensusSiteDecodesLive(t *testing.T) {
	var site cloudclient.DeployCensusSite
	if err := json.Unmarshal([]byte(`{"site_id":"s","volume":435,"failed":1,"deferred":325,"live":109}`), &site); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if site.Live == nil || *site.Live != 109 {
		t.Fatalf("Live = %v, want 109 off the wire", site.Live)
	}
	// live + deferred + failed closes over volume exactly on the real payload
	// this is modelled on — the arithmetic that makes `volume - failed -
	// deferred` unnecessary as well as forbidden.
	if 109+325+1 != site.Volume {
		t.Fatalf("cohorts do not close over volume: %d", site.Volume)
	}
	// And the absence stays distinguishable from a zero.
	var older cloudclient.DeployCensusSite
	if err := json.Unmarshal([]byte(`{"site_id":"s","volume":435,"failed":1,"deferred":325}`), &older); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if older.Live != nil {
		t.Fatalf("a control plane sending no `live` must decode to nil, got %d", *older.Live)
	}
}

// --- dr-w24-s2: the commit distance reaches the CLI ---------------------------
//
// The lie these tests exist for is measured, not hypothetical. Prod's registry
// carries, ON ONE ROW: commit_distance 2493, commit_ancestry "behind",
// update_state "current". The honest column and the reassuring column sit beside
// each other and, before this slice, only the reassuring one reached a human —
// the control plane has been measuring commit distance hourly with ZERO readers.
//
// update_state is not incapable of saying `behind` (a live row says it today).
// It is pinned: no release tag has been cut since 2026-07-08, so every box that
// reached the newest tag grades `current` however far main runs ahead of it.

// behindProdRow is the real production shape, verbatim — the row this whole
// slice exists for.
func behindProdRow() cloudclient.Barkpark {
	d := 2493
	return cloudclient.Barkpark{
		ID: "bp-1", Name: "guerrilla", Host: "h", URL: "https://guerrilla.barkpark.cloud",
		LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
		UpdateState:    "current",
		CommitDistance: &d, CommitAncestry: "behind",
		CommitDistanceCheckedAt: "2026-08-08T12:17:01Z",
	}
}

// TestCommitDistanceRowIsBehindNotOk is the predicate fix itself. MUTATION
// TARGET: narrow attentionStatus's arm back to `live && b.UpdateState ==
// "behind"` and this test REDS with status "ok" / bucket "healthy" — which is
// exactly what prod renders today.
func TestCommitDistanceRowIsBehindNotOk(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{behindProdRow()})
	if got := ranked[0].Status; got != "behind" {
		t.Fatalf("a 2,493-behind box classified %q — the commit measurement is not reaching the verdict", got)
	}
	if got := ranked[0].Bucket; got != "attention" {
		t.Fatalf("bucket = %q, want attention: a box 2,493 commits behind cannot be healthy", got)
	}
	if want := attentionRank("behind"); ranked[0].Rank != want {
		t.Fatalf("rank = %d, want the UNCHANGED behind rung %d (no new vocabulary)", ranked[0].Rank, want)
	}
}

// TestCommitDistanceEntersAttentionBucketRendered is the same fact on RENDERED
// BYTES: the row lands in ATTENTION, prints its distance, and the release-tag
// grade never stands alone.
func TestCommitDistanceEntersAttentionBucketRendered(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{behindProdRow()})
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "ATTENTION", "attention", ranked)
	got := sout.String()

	if !strings.Contains(got, "ATTENTION (1)") {
		t.Fatalf("the box must be IN the attention bucket:\n%s", got)
	}
	if !strings.Contains(got, "BEHIND") {
		t.Fatalf("the BEHIND column must appear once the plane emits an ancestry:\n%s", got)
	}
	if !strings.Contains(got, "2493") {
		t.Fatalf("the measured distance must be printed:\n%s", got)
	}
	// `current` may appear ONLY inside the sentence that contradicts it. An
	// unqualified `current` anywhere on this row is the defect.
	const qualified = "2493 commits behind main · release-tag grade still reads current"
	if !strings.Contains(got, qualified) {
		t.Fatalf("the DETAIL must name the disagreement, want %q:\n%s", qualified, got)
	}
	if n := strings.Count(got, "current"); n != 1 {
		t.Fatalf("`current` must appear exactly once, inside %q — got %d occurrences:\n%s", qualified, n, got)
	}
	if strings.Contains(got, "0 behind") {
		t.Fatalf("no row may render `0 behind`:\n%s", got)
	}
}

// TestBehindCellVocabulary pins every cell the column can print. The two that
// matter: a NULL distance is UNMETERED (never 0, never blank), and a plane that
// sent no ancestry at all yields "" so the column collapses out and an older CP
// renders byte-identical to before.
func TestBehindCellVocabulary(t *testing.T) {
	n := func(v int) *int { return &v }
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"behind prints the number", cloudclient.Barkpark{CommitAncestry: "behind", CommitDistance: n(2493)}, "2493"},
		{"measured zero is even", cloudclient.Barkpark{CommitAncestry: "current", CommitDistance: n(0)}, "even"},
		{"unknown is UNMETERED", cloudclient.Barkpark{CommitAncestry: "unknown"}, "UNMETERED"},
		{"behind with no number is UNMETERED", cloudclient.Barkpark{CommitAncestry: "behind"}, "UNMETERED"},
		{"ahead names itself", cloudclient.Barkpark{CommitAncestry: "ahead_of_main", CommitDistance: n(3)}, "ahead 3"},
		{"diverged names itself", cloudclient.Barkpark{CommitAncestry: "diverged", CommitDistance: n(5)}, "diverged 5"},
		{"an older control plane says nothing", cloudclient.Barkpark{}, ""},
	}
	for _, c := range cases {
		if got := behindCell(c.bp); got != c.want {
			t.Errorf("%s: behindCell = %q, want %q", c.name, got, c.want)
		}
	}
	// The disease, stated as a test: nothing ungradeable renders "0".
	for _, bp := range []cloudclient.Barkpark{
		{CommitAncestry: "unknown"},
		{CommitAncestry: "behind"},
		{CommitAncestry: "unknown", CommitDistanceCheckedAt: "2026-08-08T12:17:01Z"},
	} {
		if got := behindCell(bp); got == "0" {
			t.Errorf("an ungradeable box rendered %q — a NULL distance must never read as even with main", got)
		}
	}
}

// TestUnmeteredDistanceSortsToTheTop is the field's own contract
// (registry/barkpark.ex: "show NULL as unmetered and sort it to the TOP"): the
// box we could NOT grade is the first one an operator sees in its rank, not the
// one buried under the boxes we could.
func TestUnmeteredDistanceSortsToTheTop(t *testing.T) {
	n := func(v int) *int { return &v }
	// Names chosen so the pre-existing alphabetical tiebreak would put the
	// unmetered box LAST — the sort key has to be doing the work, not luck.
	fleet := []cloudclient.Barkpark{
		{ID: "a", Name: "alpha", Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
			UpdateState: "current", CommitAncestry: "behind", CommitDistance: n(617)},
		{ID: "b", Name: "beta", Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
			UpdateState: "current", CommitAncestry: "behind", CommitDistance: n(2493)},
		{ID: "z", Name: "zulu", Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
			UpdateState: "behind", CommitAncestry: "unknown", CommitDistanceCheckedAt: "2026-08-08T12:17:08Z"},
	}
	ranked := rankBarkparks(fleet)
	if ranked[0].BP.Name != "zulu" {
		t.Fatalf("order = %s,%s,%s — the UNMETERED box must sort to the top of its rank",
			ranked[0].BP.Name, ranked[1].BP.Name, ranked[2].BP.Name)
	}
	// …and the metered rows keep their own alphabetical order underneath.
	if ranked[1].BP.Name != "alpha" || ranked[2].BP.Name != "beta" {
		t.Fatalf("metered rows lost their name order: %s then %s", ranked[1].BP.Name, ranked[2].BP.Name)
	}

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "ATTENTION", "attention", ranked)
	got := sout.String()
	if !strings.Contains(got, "UNMETERED") {
		t.Fatalf("a NULL distance must render UNMETERED:\n%s", got)
	}
	iUnmetered := strings.Index(got, "UNMETERED")
	i617, i2493 := strings.Index(got, "617"), strings.Index(got, "2493")
	if iUnmetered > i617 || iUnmetered > i2493 {
		t.Fatalf("UNMETERED must be printed ABOVE every metered row (at %d, vs 617 at %d and 2493 at %d):\n%s",
			iUnmetered, i617, i2493, got)
	}
}

// TestOlderControlPlaneRendersWithoutTheBehindColumn is the compatibility rung:
// a plane that predates the emission sends no ancestry, and the view must read
// exactly as it did before this slice — no column, no sentinel, no reordering.
func TestOlderControlPlaneRendersWithoutTheBehindColumn(t *testing.T) {
	ranked := rankBarkparks([]cloudclient.Barkpark{
		{ID: "a", Name: "alpha", Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online", UpdateState: "current"},
	})
	if ranked[0].Status != "ok" {
		t.Fatalf("status = %q: an unmeasured box must not be graded behind", ranked[0].Status)
	}
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "HEALTHY", "healthy", ranked)
	got := sout.String()
	if strings.Contains(got, "BEHIND") || strings.Contains(got, "UNMETERED") {
		t.Fatalf("an older control plane must render exactly as before:\n%s", got)
	}
}

// TestStatusJSONCarriesCommitDistance pins the `-o json` projection: ancestry and
// checked_at ALWAYS present (a script can tell "the plane said nothing" from "the
// plane measured and got unknown"), the distance itself tri-state — present when
// measured, ABSENT when not, never 0.
func TestStatusJSONCarriesCommitDistance(t *testing.T) {
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{behindProdRow()})[0])
	if row["commit_distance"] != 2493 {
		t.Fatalf("commit_distance = %v, want 2493", row["commit_distance"])
	}
	if row["commit_ancestry"] != "behind" {
		t.Fatalf("commit_ancestry = %v, want behind", row["commit_ancestry"])
	}
	if row["commit_distance_checked_at"] != "2026-08-08T12:17:01Z" {
		t.Fatalf("commit_distance_checked_at = %v, want the plane's timestamp", row["commit_distance_checked_at"])
	}
	if row["status"] != "behind" || row["bucket"] != "attention" {
		t.Fatalf("the JSON verdict must agree with the table: status=%v bucket=%v", row["status"], row["bucket"])
	}

	unknown := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{{
		ID: "u", Name: "muscle-1", Host: "h", LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
		UpdateState: "current", CommitAncestry: "unknown", CommitDistanceCheckedAt: "2026-08-08T12:17:08Z",
	}})[0])
	if v, present := unknown["commit_distance"]; present {
		t.Fatalf("commit_distance must be ABSENT for an ungradeable box, got %v — a 0 there reads as even with main", v)
	}
	for _, k := range []string{"commit_ancestry", "commit_distance_checked_at"} {
		if _, present := unknown[k]; !present {
			t.Fatalf("%s must be present so a script can see WHY the distance is missing", k)
		}
	}
}

// TestBarkparkDecodesCommitDistance proves the wire type reads what router.ex
// now emits, and that an omitted distance decodes to nil rather than 0.
func TestBarkparkDecodesCommitDistance(t *testing.T) {
	var measured cloudclient.Barkpark
	if err := json.Unmarshal([]byte(`{"commit_distance":2493,"commit_ancestry":"behind","commit_distance_checked_at":"2026-08-08T12:17:01Z"}`), &measured); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if measured.CommitDistance == nil || *measured.CommitDistance != 2493 {
		t.Fatalf("CommitDistance = %v, want 2493", measured.CommitDistance)
	}
	if measured.CommitAncestry != "behind" || measured.CommitDistanceCheckedAt == "" {
		t.Fatalf("ancestry/checked_at did not decode: %+v", measured)
	}

	for _, body := range []string{`{}`, `{"commit_distance":null,"commit_ancestry":"unknown"}`} {
		var bp cloudclient.Barkpark
		if err := json.Unmarshal([]byte(body), &bp); err != nil {
			t.Fatalf("decode %s: %v", body, err)
		}
		if bp.CommitDistance != nil {
			t.Fatalf("%s decoded CommitDistance = %d, want nil — a *int is the whole point", body, *bp.CommitDistance)
		}
	}
}

// --- the serving commit (dr-w21-s3) ------------------------------------------
//
// The defect these pin: `rankedBarkparkRow` hand-builds its map, and `git_commit`
// was never typed into it — so `bp barkparks -o json` printed real shas while
// `bp cloud status -o json` printed no such key at all, off the SAME struct and
// the SAME GET /v1/barkparks response.

// commitFleet is the shape that forced this column, in miniature: boxes that
// report a serving sha, plus muscle-1 — agent offline, git_commit "", and STILL
// reading update_state `current`. The unknown box is the one the column exists
// for, so it must never render as a blank that reads "fine".
func commitFleet() []cloudclient.Barkpark {
	return []cloudclient.Barkpark{
		{ID: "g", Name: "guerrilla", Host: "h", URL: "https://guerrilla.barkpark.cloud",
			LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online", UpdateState: "current",
			GitCommit: "2673eb009f67e81f06e247e5a1504a83de699d97"},
		{ID: "d", Name: "dooodo", Host: "h", URL: "https://dooodo.barkpark.cloud",
			LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online", UpdateState: "current",
			GitCommit: "e221e7dd5f1f6ad78216562d48c5f9c8f6e5dca9"},
		{ID: "m", Name: "muscle-1", Host: "h", URL: "https://muscle-1.barkpark.cloud",
			HealthStatus: "unknown", AgentStatus: "offline", UpdateState: "current",
			GitCommit: ""},
	}
}

// TestCommitCellVocabulary pins every cell the COMMIT column can print. The one
// that matters: an absent sha is UNMETERED — never "", never the em dash
// statusDash would otherwise supply, because a blank there reads as "fine" on
// the one box already lying hardest.
func TestCommitCellVocabulary(t *testing.T) {
	cases := []struct {
		name string
		bp   cloudclient.Barkpark
		want string
	}{
		{"a full sha is shortened to 12", cloudclient.Barkpark{GitCommit: "2673eb009f67e81f06e247e5a1504a83de699d97"}, "2673eb009f67"},
		{"an already-short sha is untouched", cloudclient.Barkpark{GitCommit: "2673eb0"}, "2673eb0"},
		{"an absent sha is UNMETERED", cloudclient.Barkpark{}, "UNMETERED"},
		{"a whitespace-only sha is UNMETERED", cloudclient.Barkpark{GitCommit: "   "}, "UNMETERED"},
	}
	for _, c := range cases {
		if got := commitCell(c.bp); got != c.want {
			t.Errorf("%s: commitCell = %q, want %q", c.name, got, c.want)
		}
	}
	// The property that makes the fleet-wide switch necessary: unlike behindCell,
	// this function NEVER returns "". A per-row emptiness test could therefore
	// never serve as the column's switch.
	for _, c := range cases {
		got := commitCell(c.bp)
		if got == "" || got == "—" {
			t.Errorf("%s: commitCell = %q — the COMMIT column has no blank and no em dash", c.name, got)
		}
	}
}

// TestStatusRowCarriesGitCommit is the projection gap itself, stated as a test.
// MUTATION TARGET: delete the `"git_commit": r.BP.GitCommit,` line from
// rankedBarkparkRow and this REDS — which is exactly what main renders today.
func TestStatusRowCarriesGitCommit(t *testing.T) {
	const sha = "2673eb009f67e81f06e247e5a1504a83de699d97"
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{commitFleet()[0]})[0])
	if _, ok := row["git_commit"]; !ok {
		t.Fatalf("`bp cloud status -o json` dropped git_commit — the hand-built projection lost the key again")
	}
	// The FULL sha, untouched: shortening belongs to the table, and a script that
	// wants to compare against `git rev-parse` needs all 40 characters.
	if row["git_commit"] != sha {
		t.Fatalf("git_commit = %v, want the full sha %q untouched", row["git_commit"], sha)
	}
}

// TestStatusRowCommitKeyPresentWhenUnknown is the honesty rule commit_ancestry
// already follows: the key is ALWAYS emitted, empty when the plane does not know,
// so a consumer can tell "we asked and the plane does not know" from "this CLI
// never asked". Absent and empty are different facts.
func TestStatusRowCommitKeyPresentWhenUnknown(t *testing.T) {
	fleet := commitFleet()
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{fleet[2]})[0])
	v, ok := row["git_commit"]
	if !ok {
		t.Fatalf("git_commit must be PRESENT (empty) for an unknown commit, not absent")
	}
	if v != "" {
		t.Fatalf("git_commit = %v, want the empty string — never a fabricated sha", v)
	}
}

// TestStatusRowKeySetIsPinned pins the exact always-present key set and fails
// BOTH ways — a dropped key and an undeclared one. A hand-built map lost
// git_commit once already; this is the tripwire that stops it happening quietly
// a second time.
func TestStatusRowKeySetIsPinned(t *testing.T) {
	want := map[string]bool{
		"git_commit": true, "name": true, "slug": true, "id": true, "host": true,
		"url": true, "status": true, "bucket": true, "rank": true, "detail": true,
		"health_status": true, "agent_status": true, "update_state": true,
		"suspended": true, "update_running_release": true, "update_latest_release": true,
		"update_checked_at": true, "commit_ancestry": true,
		"commit_distance_checked_at": true, "autoupdate_paused": true,
		"pinned_release": true, "channel": true,
		// dr-w5-followup: the 5xx tri-state node — ALWAYS present, and its
		// state key is what keeps nil-as-unmeasured from collapsing into 0.
		"err_5xx": true,
	}
	// The two deliberate tri-states: emitted ONLY when the plane reported them,
	// so their absence here is the contract, not a gap.
	optional := map[string]bool{
		"autoupdate_enabled": true, "commit_distance": true,
		// jpf-w1-queue-age-alarm: emitted only when the plane reported a queued
		// row — absent is "nothing queued / older CP", never a fabricated 0.
		"queued_deploy_age_seconds": true,
	}

	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{commitFleet()[0]})[0])
	for k := range want {
		if _, ok := row[k]; !ok {
			t.Errorf("missing key %q from the `bp cloud status -o json` row (the hand-built projection dropped it)", k)
		}
	}
	for k := range row {
		if !want[k] && !optional[k] {
			t.Errorf("undeclared key %q in the `-o json` row — add it to this pin deliberately, or it is an accident", k)
		}
	}
}

// TestStatusRowNeverEmitsAgentVersion holds the line the brief drew. The registry
// `version` is the AGENT BINARY version (internal/agent/report.go `const Version
// = "0.1.0"`) — a compile-time constant that reads 0.1.0 fleet-wide while the
// boxes serve 0.2.25.164 … 0.2.25.2628. A number that can never move, printed
// beside one that does, would read as freshness.
func TestStatusRowNeverEmitsAgentVersion(t *testing.T) {
	row := rankedBarkparkRow(rankBarkparks([]cloudclient.Barkpark{commitFleet()[0]})[0])
	for _, k := range []string{"version", "agent_version"} {
		if v, ok := row[k]; ok {
			t.Errorf("row emitted %q = %v — no agent version ships beside the serving commit", k, v)
		}
	}
}

// TestStatusTableCommitColumn is the same fact on RENDERED BYTES: the header
// appears, known boxes print a short sha, and the unknown box prints UNMETERED.
func TestStatusTableCommitColumn(t *testing.T) {
	ranked := rankBarkparks(commitFleet())
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "HEALTHY", "healthy", ranked)
	got := sout.String()

	if !strings.Contains(got, "COMMIT") {
		t.Fatalf("the COMMIT column must appear once any box reports a sha:\n%s", got)
	}
	if !strings.Contains(got, "2673eb009f67") {
		t.Fatalf("the short sha must be printed:\n%s", got)
	}
	// The full sha never reaches the table — that is the -o json shape.
	if strings.Contains(got, "2673eb009f67e81f06e247e5a1504a83de699d97") {
		t.Fatalf("the table prints the SHORT sha, not all 40 characters:\n%s", got)
	}
	// The commit is a LABEL, not a verdict: it moves no box's classification.
	for _, r := range ranked {
		if r.BP.Name == "muscle-1" && r.Bucket != "attention" {
			t.Fatalf("muscle-1 left the attention bucket (%q) — the commit column must change no verdict", r.Bucket)
		}
		if r.BP.Name == "guerrilla" && r.Status != "ok" {
			t.Fatalf("guerrilla graded %q — reporting a sha must not change a verdict", r.Status)
		}
	}
}

// TestStatusCommitColumnIsFleetWideNotPerBucket is the whole subtlety of this
// column, and the reasoning carried over from the original attempt.
//
// muscle-1 sits ALONE in ATTENTION with no sha; every box that knows its sha is
// in HEALTHY. Were the switch read off the bucket being rendered — the way the
// four neighbouring conditional columns are — ATTENTION would contain no row
// with a commit, the column would switch OFF, and the one row the column exists
// for would go silent in the one place an operator actually looks.
//
// MUTATION TARGET: change renderStatusBucket to pass fleetKnowsCommit(rows)
// instead of fleetKnowsCommit(ranked) and this test REDS.
func TestStatusCommitColumnIsFleetWideNotPerBucket(t *testing.T) {
	ranked := rankBarkparks(commitFleet())

	// The fixture only proves anything if it really is the isolating shape.
	var attentionRows, attentionWithSha int
	for _, r := range ranked {
		if r.Bucket == "attention" {
			attentionRows++
			if strings.TrimSpace(r.BP.GitCommit) != "" {
				attentionWithSha++
			}
		}
	}
	if attentionRows == 0 || attentionWithSha != 0 {
		t.Fatalf("fixture is not the isolating shape: ATTENTION holds %d row(s), %d of which carry a sha — "+
			"this test is only meaningful when NO attention row knows its commit", attentionRows, attentionWithSha)
	}

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "ATTENTION", "attention", ranked)
	got := sout.String()

	if !strings.Contains(got, "COMMIT") {
		t.Fatalf("the COMMIT column went dark in ATTENTION — the switch is being read per bucket, "+
			"which silences the very row the column exists for:\n%s", got)
	}
	if !strings.Contains(got, "UNMETERED") {
		t.Fatalf("muscle-1 must say UNMETERED, not go blank:\n%s", got)
	}
	if !fleetKnowsCommit(ranked) {
		t.Fatalf("fleetKnowsCommit said no over a fleet where two boxes report a sha")
	}
}

// TestStatusCommitColumnDarkForOlderCP is the compatibility rung at the other
// end: a control plane that reports no commit for ANY box turns the column off
// entirely and renders byte-identical to before — the same older-CP honesty the
// neighbouring conditional columns follow.
func TestStatusCommitColumnDarkForOlderCP(t *testing.T) {
	fleet := commitFleet()
	for i := range fleet {
		fleet[i].GitCommit = ""
	}
	ranked := rankBarkparks(fleet)
	if fleetKnowsCommit(ranked) {
		t.Fatalf("fleetKnowsCommit said yes over a fleet where no box reports a sha")
	}
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.color = false
	renderStatusBucket(w, "HEALTHY", "healthy", ranked)
	renderStatusBucket(w, "ATTENTION", "attention", ranked)
	got := sout.String()
	if strings.Contains(got, "COMMIT") || strings.Contains(got, "UNMETERED") {
		t.Fatalf("an older control plane must render exactly as before — no column, no sentinel:\n%s", got)
	}
}

// TestErr5xxThreeStatesStayThree (dr-w5-followup-5xx-reaches-no-eyes): the
// beat's 5xx reading renders in three distinguishable states and none of them
// is another — nil (or the agent's -1 sentinel) is UNMEASURED with per_s null,
// a measured 0.0 is a real zero, a positive rate is itself. The table marker
// prints only the positive sentence (runawayMarker's policy: a table sentence
// claims something happened); the json node carries the full tri-state.
func TestErr5xxThreeStatesStayThree(t *testing.T) {
	mk := func(v *float64) cloudclient.Barkpark {
		cores := 4.0
		return cloudclient.Barkpark{Pressure: &cloudclient.Pressure{CPUCores: &cores, Err5xxPerS: v}}
	}
	pos, zero, sentinel := 0.22, 0.0, -1.0

	cases := []struct {
		name      string
		bp        cloudclient.Barkpark
		wantState string
		wantPerS  any
		wantMark  string // "" = no table sentence
	}{
		{"nil is unmeasured", mk(nil), "unmeasured", nil, ""},
		{"the -1 sentinel is unmeasured", mk(&sentinel), "unmeasured", nil, ""},
		{"a measured 0.0 is a real zero", mk(&zero), "zero", 0.0, ""},
		{"a positive rate is itself", mk(&pos), "answering", 0.22, "answering 0.22 5xx/s"},
		{"no pressure block at all is unmeasured", cloudclient.Barkpark{}, "unmeasured", nil, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			row := err5xxRow(tc.bp)
			if row["state"] != tc.wantState {
				t.Fatalf("state = %v, want %v", row["state"], tc.wantState)
			}
			if row["per_s"] != tc.wantPerS {
				t.Fatalf("per_s = %v, want %v — collapsing these states invents a measurement", row["per_s"], tc.wantPerS)
			}
			mark := err5xxMarker(tc.bp)
			if tc.wantMark == "" && mark != "" {
				t.Fatalf("table marker = %q, want none — only a happening earns a sentence", mark)
			}
			if tc.wantMark != "" && !strings.Contains(mark, tc.wantMark) {
				t.Fatalf("table marker = %q, want it to carry %q — the beat's own number, never recomputed", mark, tc.wantMark)
			}
		})
	}
}

// TestErr5xxAnsweringReachesTheDetailColumn: the D75 sentence reaches the
// table — a box the ladder calls ok, answering 0.22 5xx/s, says so on its row.
func TestErr5xxAnsweringReachesTheDetailColumn(t *testing.T) {
	cores, rate := 4.0, 0.22
	reported := "2026-08-06T12:00:00Z"
	b := cloudclient.Barkpark{
		Name: "ok-but-erroring", HealthStatus: "up", AgentStatus: "online", Host: "h",
		LastSeenAt: reported,
		Pressure: &cloudclient.Pressure{
			CPUCores: &cores, Err5xxPerS: &rate, ReportedAt: &reported,
		},
	}
	ranked := rankBarkparks([]cloudclient.Barkpark{b})
	if len(ranked) != 1 {
		t.Fatalf("rows = %d", len(ranked))
	}
	if !strings.Contains(ranked[0].Detail, "answering 0.22 5xx/s") {
		t.Fatalf("detail = %q — the 5xx reading reaches no eyes", ranked[0].Detail)
	}
	// The reading changed NO rank and NO bucket — the ruling is a detail line.
	if ranked[0].Status != "ok" || ranked[0].Bucket != "healthy" {
		t.Fatalf("status/bucket = %s/%s — the 5xx detail line must not move the ladder", ranked[0].Status, ranked[0].Bucket)
	}
}

// statusJSONWith drives `bp cloud status -o json` against a fake whose census
// and site routes are supplied per case, returning the decoded payload.
func statusJSONWith(t *testing.T, censusHandler, sitesHandler http.HandlerFunc) map[string]any {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/deploy-ledger/census":
			censusHandler(w, r)
		case "/v1/sites":
			sitesHandler(w, r)
		default:
			_, _ = io.WriteString(w, `{"barkparks":[
				{"id":"bp-1","name":"box-one","host":"h","last_seen_at":"2026-08-06T12:00:00Z","health_status":"up","agent_status":"online"}
			]}`)
		}
	}))
	t.Cleanup(srv.Close)
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runCloudStatus(out, globals{}, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(stdout), &payload); err != nil {
		t.Fatalf("decode: %v\n%s", err, stdout)
	}
	return payload
}

// statusJSONDeployNodes extracts the fleet deploy node and box-one's row node.
func statusJSONDeployNodes(t *testing.T, payload map[string]any) (map[string]any, map[string]any) {
	t.Helper()
	fleet, ok := payload["deploy"].(map[string]any)
	if !ok {
		t.Fatalf("payload has no fleet deploy node: %v", payload)
	}
	rows, ok := payload["barkparks"].([]any)
	if !ok || len(rows) == 0 {
		t.Fatalf("payload has no barkpark rows: %v", payload)
	}
	row, ok := rows[0].(map[string]any)
	if !ok {
		t.Fatalf("row shape: %v", rows[0])
	}
	box, ok := row["deploy"].(map[string]any)
	if !ok {
		t.Fatalf("row has no deploy node — a refusal must be a NAMED key, never an omitted one: %v", row)
	}
	return fleet, box
}

// TestRunCloudStatusJSONDeployRefusalShapes pins the four refusal shapes of
// the json deploy node (dr-w19-s7 followup). Each is a NAMED state with its
// reason; live/volume/pct are null wherever they were not measured — never an
// omitted key and never a zero standing in for "could not say".
func TestRunCloudStatusJSONDeployRefusalShapes(t *testing.T) {
	serve := func(body string, status int) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
			_, _ = io.WriteString(w, body)
		}
	}
	okSites := serve(`{"sites":[{"id":"site-1","barkpark_id":"bp-1","name":"s1"}]}`, 200)
	censusFor := func(siteRow string) http.HandlerFunc {
		return serve(`{"volume":50,"failed":10,"failure_rate":{"sample":50,"pct":null,"numerator":10,"min_sample":200,"refused":true,"reason":"sample 50 below min_sample 200"},"classes":[],"not_attempted":[],"sites":[`+siteRow+`],"min_sample":200}`, 200)
	}

	t.Run("census_unreadable", func(t *testing.T) {
		withTempConfigHome(t)
		payload := statusJSONWith(t, serve(`{"error":"forbidden"}`, 403), okSites)
		fleet, box := statusJSONDeployNodes(t, payload)
		if fleet["state"] != "census_unreadable" || fleet["reason"] == nil || fleet["reason"] == "" {
			t.Fatalf("fleet = %v, want state census_unreadable with a reason", fleet)
		}
		if box["state"] != "census_unreadable" || box["live"] != nil || box["volume"] != nil || box["pct"] != nil {
			t.Fatalf("box = %v, want the refusal echoed with null measurements", box)
		}
	})

	t.Run("sites_unattributable", func(t *testing.T) {
		withTempConfigHome(t)
		payload := statusJSONWith(t, censusFor(``), serve(`boom`, 500))
		fleet, box := statusJSONDeployNodes(t, payload)
		if fleet["state"] != "sites_unattributable" {
			t.Fatalf("fleet = %v, want sites_unattributable", fleet)
		}
		reason, _ := fleet["reason"].(string)
		if !strings.Contains(reason, "50 attempted rows") {
			t.Fatalf("reason %q must carry the census volume that WAS read", reason)
		}
		if box["state"] != "sites_unattributable" || box["live"] != nil || box["volume"] != nil || box["pct"] != nil {
			t.Fatalf("box = %v, want the refusal echoed with null measurements", box)
		}
	})

	t.Run("live_unmetered", func(t *testing.T) {
		withTempConfigHome(t)
		// The site row carries volume but NO `live` key — a control plane
		// predating #10519. live must be null, never 0.
		payload := statusJSONWith(t, censusFor(`{"site_id":"site-1","volume":50,"failed":10,"deferred":5,"failure_rate":{"sample":50,"pct":null,"numerator":10,"min_sample":200,"refused":true,"reason":"sample 50 below min_sample 200"}}`), okSites)
		fleet, box := statusJSONDeployNodes(t, payload)
		if fleet["state"] != "read" {
			t.Fatalf("fleet = %v, want read", fleet)
		}
		if box["state"] != "live_unmetered" || box["live"] != nil || box["volume"] != float64(50) || box["pct"] != nil {
			t.Fatalf("box = %v, want live_unmetered with live null and volume 50", box)
		}
		reason, _ := box["reason"].(string)
		if !strings.Contains(reason, "never read this as zero") {
			t.Fatalf("reason %q must forbid the zero reading", reason)
		}
	})

	t.Run("below_min_sample", func(t *testing.T) {
		withTempConfigHome(t)
		payload := statusJSONWith(t, censusFor(`{"site_id":"site-1","volume":50,"failed":10,"deferred":5,"live":35,"failure_rate":{"sample":50,"pct":null,"numerator":10,"min_sample":200,"refused":true,"reason":"sample 50 below min_sample 200"}}`), okSites)
		fleet, box := statusJSONDeployNodes(t, payload)
		if ms, ok := fleet["min_sample"].(float64); !ok || ms != 200 {
			t.Fatalf("fleet.min_sample = %v, want 200", fleet["min_sample"])
		}
		if box["state"] != "below_min_sample" || box["pct"] != nil {
			t.Fatalf("box = %v, want below_min_sample with pct null", box)
		}
		// The COUNTS are real and stay — only the percentage is refused.
		if box["live"] != float64(35) || box["volume"] != float64(50) {
			t.Fatalf("box = %v, want live 35 / volume 50 (counts stay; ratios go)", box)
		}
	})
}
