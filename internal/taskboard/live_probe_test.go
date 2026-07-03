//go:build liveprobe

package taskboard

import (
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TestLiveProbe is a manual wire-contract probe (go test -tags liveprobe
// -run TestLiveProbe with BP_SERVER/BP_TOKEN set). Never runs in CI.
func TestLiveProbe(t *testing.T) {
	server, token := os.Getenv("BP_SERVER"), os.Getenv("BP_TOKEN")
	if server == "" || token == "" {
		t.Skip("BP_SERVER/BP_TOKEN not set")
	}
	c := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	snap, err := FetchSnapshot(c)
	if err != nil {
		t.Fatalf("FetchSnapshot: %v", err)
	}
	fmt.Printf("tasks=%d counts=%v events=%d fetched=%s\n", len(snap.Tasks), snap.Counts, len(snap.Events), snap.FetchedAt.Format(time.RFC3339))
	ready, claims, withCriteria := 0, 0, 0
	for _, tk := range snap.Tasks {
		if tk.Lifecycle == "ready" {
			ready++
		}
		if tk.Claim != nil && tk.Claim.Worker != "" {
			claims++
		}
		if tk.Criteria != nil {
			withCriteria++
		}
	}
	fmt.Printf("overlaid-ready=%d live-claims=%d with-criteria=%d\n", ready, claims, withCriteria)
	b := BuildBoard(snap, RepoContext{}, time.Now().UTC())
	fmt.Printf("board: now=%d epics=%d orphans=%d\n", len(b.Now), len(b.Epics), len(b.Orphans))
	for i, e := range b.Epics {
		if i >= 6 {
			break
		}
		fmt.Printf("  epic %-30q children=%d folded=%d dormant=%v\n", e.Root.Title, len(e.Children), e.DoneFolded, e.Dormant)
	}
	for i, tk := range b.Now {
		if i >= 5 {
			break
		}
		fmt.Printf("  NOW %-40q worker=%s age=%s\n", tk.Title, tk.Claim.Worker, time.Since(tk.Claim.ClaimedAt).Round(time.Minute))
	}
}
