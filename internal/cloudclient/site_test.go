package cloudclient

// site_test.go pins the spawned-site (site-spawner) client contract that the CLI's
// deploy stream depends on for its honesty: which deployment statuses END the poll
// loop, and that the six visible stages keep their canonical order.
//
// The terminal set is load-bearing, not cosmetic: the CLI polls until it is true, so
// a real terminal status missing from it means the stream spins its full budget
// (300 × 2s ≈ 10 min) and then tells the user the deploy is "in progress" — which is
// exactly what `cancelled` used to do.

import "testing"

func TestSiteDeploymentTerminal(t *testing.T) {
	terminal := []string{
		"live", "failed", "cancelled",
		"canceled", // the other spelling of the same end-state
		"  LIVE  ", // whitespace + case are the server's business, not ours
		"Cancelled",
	}
	for _, s := range terminal {
		if !SiteDeploymentTerminal(s) {
			t.Fatalf("SiteDeploymentTerminal(%q) = false, want true — the deploy stream would poll ~10 min and then report it as in progress", s)
		}
	}
	// Every non-terminal status of the six-value enum, plus the empty string, must
	// keep the loop polling.
	for _, s := range []string{"queued", "building", "pushing", "", "unknown"} {
		if SiteDeploymentTerminal(s) {
			t.Fatalf("SiteDeploymentTerminal(%q) = true, want false — the stream would stop before the deploy landed", s)
		}
	}
}

// TestSpawnSiteStagesOrder pins the six visible stages and their order — the bar the
// CLI renders and the deploy engine walks.
func TestSpawnSiteStagesOrder(t *testing.T) {
	want := []string{"PLAN", "BUILD", "STAGE", "HEALTH", "SWITCH", "RETIRE"}
	if len(SpawnSiteStages) != len(want) {
		t.Fatalf("SpawnSiteStages = %v, want %v", SpawnSiteStages, want)
	}
	for i, name := range want {
		if SpawnSiteStages[i] != name {
			t.Fatalf("SpawnSiteStages[%d] = %q, want %q (order is the contract)", i, SpawnSiteStages[i], name)
		}
	}
}
