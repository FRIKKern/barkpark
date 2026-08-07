package cli

import (
	"bytes"
	"encoding/json"
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

// TestAttentionLadderIsElevenRungs pins the ladder itself — order and length —
// so a rung inserted at the wrong height (which silently re-buckets its
// neighbours) fails here rather than in an operator's terminal.
func TestAttentionLadderIsElevenRungs(t *testing.T) {
	want := []string{
		"removal_failed", "failed", "suspended", "degraded",
		"strained", "filling", "unreported", "behind",
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
		{"behind", 8, "attention"}, // the LAST attention rung
		{"removing", 9, "in-flight"},
		{"provisioning", 10, "in-flight"},
		{"ok", 11, "healthy"}, // the ONLY healthy rung
	} {
		if got := attentionRank(c.state); got != c.rank {
			t.Errorf("attentionRank(%q) = %d, want %d", c.state, got, c.rank)
		}
		if got := attentionBucket(c.state); got != c.bucket {
			t.Errorf("attentionBucket(%q) = %q, want %q", c.state, got, c.bucket)
		}
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

	var gotPath, gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
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
	if gotPath != "/v1/barkparks" {
		t.Fatalf("hit %q, want /v1/barkparks", gotPath)
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
		Barkparks []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Bucket string `json:"bucket"`
			Rank   int    `json:"rank"`
			Detail string `json:"detail"`
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
	// failed (2) < degraded (4) < strained (5) < filling (6) < ok (11).
	wantOrder := []string{"dead-box", "slow-box", "hot-box", "full-box", "ok-box"}
	wantStatus := []string{"failed", "degraded", "strained", "filling", "ok"}
	wantRank := []int{2, 4, 5, 6, 11}
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
