package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func closedClaimRow(t *testing.T, id, lifecycle string) json.RawMessage {
	t.Helper()
	row, err := json.Marshal(map[string]any{"doc_id": id, "lifecycle_status": lifecycle, "claim": json.RawMessage(closedClaim)})
	if err != nil {
		t.Fatal(err)
	}
	return row
}

func TestTaskScanClaimedSkipsAClosedClaim(t *testing.T) {
	closed := closedClaimRow(t, "t-done", "done")
	live := json.RawMessage(`{"doc_id":"t-live","lifecycle_status":"in_progress","claim":{"worker":"drop-clock","epoch":3}}`)
	for _, o := range []taskScanOpts{{claimed: true}, {claimedBy: "drop-clock"}} {
		m := taskScanRowMatcher(o)
		if !m(live) {
			t.Fatalf("%+v: a live claim must match", o)
		}
		if m(closed) {
			t.Errorf("%+v: a closed claim (closed_by=drop-clock) is listed as held", o)
		}
	}
}

func TestClaimVerdictOnABlockedCloseNamesNoLiveHolder(t *testing.T) {
	var doc apiclient.Doc
	if err := json.Unmarshal(closedClaimRow(t, "t-blocked", "blocked"), &doc); err != nil {
		t.Fatal(err)
	}
	got := claimVerdict("other", "blocked", doc.ClaimInfo(), queueGate{}, "")
	if strings.Contains(got, "held live by") {
		t.Errorf("a row closed blocked is diagnosed as held: %q", got)
	}
	if !strings.Contains(got, `lifecycle_status is "blocked", not an open/claimable state`) {
		t.Errorf("a row closed blocked must be named by its lifecycle: %q", got)
	}
}

func TestReadTaskClaimsSkipsAClosedClaim(t *testing.T) {
	page := `{"docs":[{"doc_id":"t-done","claim":` + closedClaim + `},{"doc_id":"t-live","claim":{"worker":"lead-api-1","epoch":1}}]}`
	report, err := readTaskClaims([]byte(page), taskLsCommandID, taskReadShapes()[taskLsCommandID])
	if err != nil {
		t.Fatal(err)
	}
	if report.Claimed != 1 || len(report.Workers) != 1 || report.Workers[0] != "lead-api-1" {
		t.Errorf("only the live claim counts as CLAIMED; got claimed=%d workers=%v", report.Claimed, report.Workers)
	}
}
