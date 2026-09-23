package taskboard

import (
	"os"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// TestLiveHydrateProbe is the LANDED instrument for the `?view=board` trade,
// not a gate: it proves against a REAL server that the per-row hydration route
// answers with the prose the board projection deletes.
//
// It exists because the number that justifies `?view=board` (105,755,961 B of
// corpus walk down to 13,035,765 B) is only honest if the prose comes back from
// somewhere, and "somewhere" is a route no unit test can reach. A throwaway
// curl proves it once for the person who ran it; this proves it for whoever
// reads the file next.
//
// SKIPPED unless all three env vars are set, and it reads NO config file and no
// token from disk — the credential is the caller's to supply:
//
//	BARKPARK_LIVE_SERVER=https://guerrilla.barkpark.cloud \
//	BARKPARK_LIVE_TOKEN=... \
//	BARKPARK_LIVE_PROBE=task-… \
//	  CGO_ENABLED=0 go test ./internal/taskboard/ -run TestLiveHydrateProbe -v
func TestLiveHydrateProbe(t *testing.T) {
	id := os.Getenv("BARKPARK_LIVE_PROBE")
	server := os.Getenv("BARKPARK_LIVE_SERVER")
	token := os.Getenv("BARKPARK_LIVE_TOKEN")
	if id == "" || server == "" || token == "" {
		t.Skip("set BARKPARK_LIVE_SERVER, BARKPARK_LIVE_TOKEN and BARKPARK_LIVE_PROBE to run the live probe")
	}
	c := apiclient.New(apiclient.Config{BaseURL: server, Token: token})
	d, err := FetchTaskDetailByID(c, id)
	if err != nil {
		t.Fatalf("FetchTaskDetailByID(%s): %v", id, err)
	}
	t.Logf("doc_id=%s rev=%s description=%dB criteria=%d evidence=%d papers=%v design_doc=%q",
		d.DocID, d.Rev, len(d.Description), len(d.CriteriaItems), len(d.Evidence), d.Papers, d.DesignDoc)
	if d.DocID != id {
		t.Fatalf("the row route answered with doc_id=%q for a request for %q", d.DocID, id)
	}
	if d.Description == "" && len(d.CriteriaItems) == 0 {
		t.Fatalf("live hydration came back with NO prose at all for %s: the route the board pays a round-trip for is not carrying what `?view=board` deleted", id)
	}
}
