package cli

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// --- dr-w10-s1: the verdict reads the deploy rate -----------------------------
//
// THE LIE THESE TESTS EXIST FOR IS RECORDED, NOT HYPOTHETICAL. On 2026-08-07
// guerrilla failed 46.28% of its 1,290 terminal deploys in 24h and `bp cloud
// status` printed `ok` for it — from a bare `default:` arm that read no deploy
// vital at all, because none was on the wire. Every shape below is that row or
// one of its two siblings (a box with sites we could not score; a box with no
// sites at all), and the three must never render as each other.

// guerrillaShapedRow is the recorded shape, verbatim: a live, healthy-beating
// box whose ONLY problem is that its deploys do not land.
func guerrillaShapedRow() cloudclient.Barkpark {
	pct := 46.28
	box := 31.5
	return cloudclient.Barkpark{
		ID: "bp-guerrilla", Name: "guerrilla", Host: "10.0.0.20",
		LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
		DeployRate: &cloudclient.BoxDeployRate{
			Sites: 7, SitesDeploying: 7,
			Window: &cloudclient.DeployCensusWindow{
				From: "2026-08-06T12:00:00Z", To: "2026-08-07T12:00:00Z",
			},
			Rate:      cloudclient.DeployRate{Sample: 1290, Pct: &pct, Numerator: 597, MinSample: 200},
			BoxCaused: cloudclient.DeployRate{Sample: 597, Pct: &box, Numerator: 188, MinSample: 200},
		},
	}
}

// TestDeploysFailingDirectionOne (row C5) — MUTATION DIRECTION ONE. Replaying
// the recorded guerrilla row through attentionStatus must return
// `deploys_failing`, and the assertion is written as NOT ok as well, because
// `ok` is the exact wrong answer this slice exists to end. Deleting the rung's
// arm from attentionStatus reds this test.
func TestDeploysFailingDirectionOne(t *testing.T) {
	b := guerrillaShapedRow()
	if got := attentionStatus(b); got != "deploys_failing" {
		t.Fatalf("attentionStatus = %q, want deploys_failing", got)
	}
	if got := attentionStatus(b); got == "ok" {
		t.Fatalf("the recorded 46.28%%-of-1290 row rendered ok — the defect is back")
	}
	if got := attentionBucket(attentionStatus(b)); got != "attention" {
		t.Fatalf("bucket = %q, want attention", got)
	}
	if got := attentionRank("deploys_failing"); got != 5 {
		t.Fatalf("rank = %d, want 5 (directly under degraded)", got)
	}
	// The sentence never quotes a percentage without its denominator.
	detail := attentionDetail(b, attentionStatus(b))
	for _, want := range []string{"46.3", "1290", "fence 20", "box-caused"} {
		if !strings.Contains(detail, want) {
			t.Errorf("detail %q is missing %q", detail, want)
		}
	}
	// And it names the window the control plane pinned.
	if !strings.Contains(detail, "2026-08-06T12:00:00Z") {
		t.Errorf("detail %q does not carry its window", detail)
	}
}

// TestDeploysFailingFenceIsNotTooBroad is the negative direction of the same
// arm: the fence is charter D150's 20.0, ABOVE the 9.5% site-caused floor, so a
// fleet of ordinary broken customer builds must NOT trip it. A fence lowered to
// catch more would red here.
func TestDeploysFailingFenceIsNotTooBroad(t *testing.T) {
	b := guerrillaShapedRow()
	under := 19.9
	b.DeployRate.Rate.Pct = &under
	if got := attentionStatus(b); got != "ok" {
		t.Fatalf("19.9%% (under the D150 fence) = %q, want ok", got)
	}
	at := 20.0
	b.DeployRate.Rate.Pct = &at
	if got := attentionStatus(b); got != "deploys_failing" {
		t.Fatalf("the fence is >=, so 20.0%% = %q, want deploys_failing", got)
	}
}

// TestDeploysUnmeteredAndNoSurfaceDirectionTwo (row C6) — MUTATION DIRECTION
// TWO, and the whole reason the split is three-way rather than two.
//
// A REFUSED rate (sample under min_sample) is a SILENCE: the box has sites and
// we could not score them. Per charter D69 and the orchestrator's 2026-09-06
// ruling it is a DETAIL MARKER, not a rung — so the verdict is unchanged and the
// row says, in words, that it was not measured. It must never render as a clean
// `ok` with an empty detail, which is the shape the defect wore.
//
// A box with ZERO SITES is a different fact: it has nothing to deploy and has
// not failed to report. Verdict `ok`, and a marker saying which of the two it
// is. Folding these together would put 6 of 8 prod boxes in a permanent alarm.
func TestDeploysUnmeteredAndNoSurfaceDirectionTwo(t *testing.T) {
	// (a) has sites, refused sample.
	refused := guerrillaShapedRow()
	refused.DeployRate.Rate = cloudclient.DeployRate{
		Sample: 55, Pct: nil, MinSample: 200, Refused: true,
		Reason: "sample 55 is below the 200-row floor",
	}
	if got := attentionStatus(refused); got != "ok" {
		t.Fatalf("a refused rate must not invent a rung: %q", got)
	}
	if kind, _ := deployVerdict(refused); kind != deployUnmetered {
		t.Fatalf("verdict kind = %v, want deployUnmetered", kind)
	}
	detail := attentionDetail(refused, attentionStatus(refused))
	if detail == "" {
		t.Fatalf("a box with sites and no readable rate rendered ok with an EMPTY detail — the defect's exact shape")
	}
	for _, want := range []string{"unmetered", "7 site", "200"} {
		if !strings.Contains(detail, want) {
			t.Errorf("unmetered detail %q is missing %q", detail, want)
		}
	}
	if strings.Contains(detail, "%") {
		t.Errorf("an unmetered row must never quote a percentage: %q", detail)
	}

	// (b) has sites, control plane sent no pct at all (not flagged refused).
	absent := guerrillaShapedRow()
	absent.DeployRate.Rate = cloudclient.DeployRate{Sample: 0, Pct: nil, MinSample: 200}
	if kind, _ := deployVerdict(absent); kind != deployUnmetered {
		t.Fatalf("an absent pct on a box WITH sites must be unmetered, got %v", kind)
	}

	// (c) zero sites: ok, WITH the marker present.
	empty := guerrillaShapedRow()
	empty.DeployRate = &cloudclient.BoxDeployRate{Sites: 0, SitesDeploying: 0}
	if got := attentionStatus(empty); got != "ok" {
		t.Fatalf("a box with nothing to deploy = %q, want ok", got)
	}
	if kind, _ := deployVerdict(empty); kind != deployNoSurface {
		t.Fatalf("verdict kind = %v, want deployNoSurface", kind)
	}
	got := attentionDetail(empty, "ok")
	if !strings.Contains(got, "no deploy surface") {
		t.Fatalf("the zero-sites marker is missing from %q", got)
	}

	// (d) an OLDER control plane that never sent the key says nothing about
	// this box — no marker, no alarm. The three absences stay three.
	older := guerrillaShapedRow()
	older.DeployRate = nil
	if got := attentionDetail(older, attentionStatus(older)); got != "" {
		t.Fatalf("an older control plane must invent no sentence, got %q", got)
	}
}

// TestBoxDeployRateDecodesNullPct (row C4) — the DECODER pin. A refusing node
// sends `"pct": null` and a plain float64 would decode that as 0.0: a box we
// could not measure would read as a box with a perfect record. Pct is *float64
// for exactly this, and the fixture below is the refusal on the wire.
func TestBoxDeployRateDecodesNullPct(t *testing.T) {
	const wire = `{
	  "window": {"from":"2026-08-06T12:00:00Z","to":"2026-08-07T12:00:00Z"},
	  "sites": 3, "sites_deploying": 0,
	  "rate": {"sample":55,"pct":null,"numerator":0,"min_sample":200,"refused":true,
	           "reason":"sample 55 is below the 200-row floor","basis":"TERMINAL rows only"},
	  "absorption": {"sample":55,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"r","basis":"b"},
	  "box_caused": {"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"r","basis":"b"}
	}`
	var node cloudclient.BoxDeployRate
	if err := json.Unmarshal([]byte(wire), &node); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if node.Rate.Pct != nil {
		t.Fatalf("a JSON null pct decoded to %v — a refusal became a number", *node.Rate.Pct)
	}
	if node.Absorption.Pct != nil || node.BoxCaused.Pct != nil {
		t.Fatalf("the companion rates must refuse too, got %v / %v", node.Absorption.Pct, node.BoxCaused.Pct)
	}
	if node.Rate.Sample != 55 || node.Rate.MinSample != 200 || !node.Rate.Refused {
		t.Fatalf("the refusal lost its denominator: %+v", node.Rate)
	}
	if node.Sites != 3 || node.SitesDeploying != 0 {
		t.Fatalf("site counts = %d/%d, want 3/0", node.Sites, node.SitesDeploying)
	}
	// And a MEASURED node keeps its number — the pointer must not swallow zero.
	var zero cloudclient.BoxDeployRate
	if err := json.Unmarshal([]byte(`{"sites":1,"rate":{"sample":400,"pct":0,"min_sample":200}}`), &zero); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if zero.Rate.Pct == nil || *zero.Rate.Pct != 0 {
		t.Fatalf("a real 0.0%% must decode to 0, not nil: %v", zero.Rate.Pct)
	}
}

// TestAttentionStatusOutputsAreASubsetOfTheLadder (row C9) closes the ENUM HOLE
// this slice widens. TestAttentionVocabularyMatchesFixture pins the LADDER
// against the fixture but says nothing about what attentionStatus can RETURN —
// which was proved by mutation: a status not on the ladder escaped the function
// with every existing test green, ranked past the end and bucketed by the
// defensive default. This asserts the other direction.
func TestAttentionStatusOutputsAreASubsetOfTheLadder(t *testing.T) {
	live := func(mut func(*cloudclient.Barkpark)) cloudclient.Barkpark {
		b := cloudclient.Barkpark{
			ID: "x", Name: "x", Host: "10.0.0.1",
			LastSeenAt: seen, HealthStatus: "up", AgentStatus: "online",
		}
		if mut != nil {
			mut(&b)
		}
		return b
	}
	pct := func(v float64) *float64 { return &v }
	cores, load, disk := 2.0, 9.0, 99.0

	shapes := []cloudclient.Barkpark{
		live(nil),
		live(func(b *cloudclient.Barkpark) { b.DeprovisionStatus = "failed" }),
		live(func(b *cloudclient.Barkpark) { b.Host = ""; b.ProvisionStatus = "failed" }),
		live(func(b *cloudclient.Barkpark) { b.Suspended = true }),
		live(func(b *cloudclient.Barkpark) { b.LastSeenAt = "" }),
		live(func(b *cloudclient.Barkpark) { b.HealthStatus = "down" }),
		live(func(b *cloudclient.Barkpark) { b.QueuedDeployAgeSecondsMissing = true }),
		guerrillaShapedRow(),
		live(func(b *cloudclient.Barkpark) {
			b.DeployRate = &cloudclient.BoxDeployRate{Sites: 2,
				Rate: cloudclient.DeployRate{Sample: 9, MinSample: 200, Refused: true}}
		}),
		live(func(b *cloudclient.Barkpark) {
			b.DeployRate = &cloudclient.BoxDeployRate{Sites: 0}
		}),
		live(func(b *cloudclient.Barkpark) {
			b.DeployRate = &cloudclient.BoxDeployRate{Sites: 4,
				Rate: cloudclient.DeployRate{Sample: 900, Pct: pct(1.2), MinSample: 200}}
		}),
		live(func(b *cloudclient.Barkpark) { b.CommitAncestry = "diverged" }),
		live(func(b *cloudclient.Barkpark) { b.CommitAncestry = "behind" }),
		live(func(b *cloudclient.Barkpark) { b.UpdateState = "behind" }),
		live(func(b *cloudclient.Barkpark) {
			b.Pressure = &cloudclient.Pressure{CPUCores: &cores, Load15: &load}
		}),
		live(func(b *cloudclient.Barkpark) {
			b.Pressure = &cloudclient.Pressure{DiskUsedPercent: &disk}
		}),
		live(func(b *cloudclient.Barkpark) {
			s := 420.0
			b.QueuedDeployAgeSeconds = &s
		}),
		live(func(b *cloudclient.Barkpark) { b.DeprovisionStatus = "pending" }),
		live(func(b *cloudclient.Barkpark) { b.Host = "" }),
	}

	seenStatuses := map[string]bool{}
	for i, b := range shapes {
		got := attentionStatus(b)
		if !slices.Contains(attentionRankOrder, got) {
			t.Fatalf("shape %d returned %q, which is NOT on the ladder %v — an unranked status ranks past the end and is invisible to every fixture pin",
				i, got, attentionRankOrder)
		}
		seenStatuses[got] = true
	}
	// Non-vacuity: a table that only ever produced `ok` would pass the subset
	// assertion while proving nothing. Both new rungs must be REACHED here.
	for _, must := range []string{"deploys_failing", "diverged", "ok"} {
		if !seenStatuses[must] {
			t.Fatalf("the shape table never produced %q — the subset assertion is vacuous for it", must)
		}
	}
}
