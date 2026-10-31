package taskboard

import (
	"encoding/json"
	"testing"
)

func TestDecodeCriterionReadsConfirmations(t *testing.T) {
	raw := json.RawMessage(`{"criterion":"new wording","met":false,
		"confirmations":[{"note":"read it","worker":"reviewer","ts":"2026-10-31T09:00:00Z","amendment":1}, "junk"]}`)
	got := decodeCriterion(raw).Confirmations
	if len(got) != 1 || got[0].Note != "read it" || got[0].Worker != "reviewer" {
		t.Fatalf("confirmations must decode with the attempt tolerance, got %+v", got)
	}
}
