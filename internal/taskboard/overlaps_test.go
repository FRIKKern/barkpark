package taskboard

import "testing"

// TestClaimOverlapsFileCollision — two in_progress claims declaring the same
// file collide (kind "files", the shared path named); a third disjoint claim
// stays silent. Workers are carried with AID < BID ordering.
func TestClaimOverlapsFileCollision(t *testing.T) {
	now := []Task{
		{DocID: "a", Claim: &Claim{Worker: "w1"}, Labels: []string{"files:internal/cli/onramp_cmd.go"}},
		{DocID: "b", Claim: &Claim{Worker: "w2"}, Labels: []string{"files:internal/cli/onramp_cmd.go"}},
		{DocID: "c", Claim: &Claim{Worker: "w3"}, Labels: []string{"files:internal/taskboard/board.go"}},
	}
	pairs := ClaimOverlaps(now)
	if len(pairs) != 1 {
		t.Fatalf("overlaps = %d, want 1 (a⋈b share onramp_cmd.go; c disjoint)", len(pairs))
	}
	p := pairs[0]
	if p.AID != "a" || p.BID != "b" {
		t.Errorf("pair = %s,%s want a,b", p.AID, p.BID)
	}
	if p.Kind != "files" || p.Shared != "internal/cli/onramp_cmd.go" {
		t.Errorf("shared = %q %q, want files internal/cli/onramp_cmd.go", p.Kind, p.Shared)
	}
	if p.AWorker != "w1" || p.BWorker != "w2" {
		t.Errorf("workers = %s,%s want w1,w2", p.AWorker, p.BWorker)
	}
}

// TestClaimOverlapsDirPrefix — a directory-prefix claim collides with any claim
// under it.
func TestClaimOverlapsDirPrefix(t *testing.T) {
	now := []Task{
		{DocID: "dir", Claim: &Claim{Worker: "w1"}, Labels: []string{"files:internal/taskboard/"}},
		{DocID: "file", Claim: &Claim{Worker: "w2"}, Labels: []string{"files:internal/taskboard/frontier.go"}},
	}
	pairs := ClaimOverlaps(now)
	if len(pairs) != 1 || pairs[0].Shared != "internal/taskboard/" {
		t.Fatalf("overlaps = %+v, want 1 pair sharing internal/taskboard/", pairs)
	}
}

// TestClaimOverlapsAuthoredArea — absent a file collision, an AUTHORED area:
// overlap surfaces (kind "area"); a disjoint area stays silent.
func TestClaimOverlapsAuthoredArea(t *testing.T) {
	now := []Task{
		{DocID: "x", Claim: &Claim{Worker: "w1"}, Labels: []string{"area:studio"}},
		{DocID: "y", Claim: &Claim{Worker: "w2"}, Labels: []string{"area:studio"}},
		{DocID: "z", Claim: &Claim{Worker: "w3"}, Labels: []string{"area:cli"}},
	}
	pairs := ClaimOverlaps(now)
	if len(pairs) != 1 {
		t.Fatalf("overlaps = %d, want 1 (x⋈y share area:studio)", len(pairs))
	}
	if pairs[0].Kind != "area" || pairs[0].Shared != "area:studio" {
		t.Errorf("pair = %q %q, want area area:studio", pairs[0].Kind, pairs[0].Shared)
	}
}

// TestClaimOverlapsSilent — undeclared claims never collide (nothing to prove),
// and a derived-only (~) area is not an authored collision.
func TestClaimOverlapsSilent(t *testing.T) {
	bare := []Task{
		{DocID: "p", Claim: &Claim{Worker: "w1"}},
		{DocID: "q", Claim: &Claim{Worker: "w2"}},
	}
	if got := ClaimOverlaps(bare); len(got) != 0 {
		t.Errorf("undeclared overlaps = %+v, want none", got)
	}
	// two derived-only (~studio) claims are NOT an authored collision.
	derived := []Task{
		{DocID: "p", Claim: &Claim{Worker: "w1"}, Labels: []string{"phase:2-studio"}},
		{DocID: "q", Claim: &Claim{Worker: "w2"}, Labels: []string{"phase:2-studio"}},
	}
	if got := ClaimOverlaps(derived); len(got) != 0 {
		t.Errorf("derived-only overlaps = %+v, want none (authored areas only)", got)
	}
}

// TestClaimOverlapsFileBeatsArea — when a pair collides on BOTH files and area,
// the file signal wins (more precise) and only one pair is emitted.
func TestClaimOverlapsFileBeatsArea(t *testing.T) {
	now := []Task{
		{DocID: "a", Claim: &Claim{Worker: "w1"}, Labels: []string{"area:cli", "files:internal/cli/x.go"}},
		{DocID: "b", Claim: &Claim{Worker: "w2"}, Labels: []string{"area:cli", "files:internal/cli/x.go"}},
	}
	pairs := ClaimOverlaps(now)
	if len(pairs) != 1 || pairs[0].Kind != "files" {
		t.Fatalf("overlaps = %+v, want 1 file pair (file signal wins)", pairs)
	}
}
