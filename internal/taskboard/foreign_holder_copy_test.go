package taskboard

import (
	"errors"
	"strings"
	"testing"
)

// r4-lane-c dogfood: on a task claimed by someone else, 'c' said "already in
// progress — press x to close it instead", x armed "press x again to close",
// and the second x ended in "close rejected: not_holder:studio:admin". The
// pointer sent the user to a close only the holder may make, and the refusal
// spoke wire code. Name the holder instead.
func TestClaimOnForeignHeldRowNamesTheHolder(t *testing.T) {
	foreign := Task{DocID: "t1", Title: "Add dark mode", Lifecycle: lifeInProgress, Claim: &Claim{Worker: "studio:admin", Epoch: 1}}
	got := claimBlockedReason(foreign, "cmux:me")
	if !strings.Contains(got, "studio:admin") || strings.Contains(got, "press x") {
		t.Fatalf("claim on a foreign-held row = %q, want the holder named and no pointer at x", got)
	}

	mine := Task{DocID: "t2", Title: "Mine", Lifecycle: lifeInProgress, Claim: &Claim{Worker: "cmux:me", Epoch: 1}}
	if got := claimBlockedReason(mine, "cmux:me"); !strings.Contains(got, "press x") {
		t.Fatalf("claim on my own in-flight row = %q, want the pointer at x kept", got)
	}
}

func TestNotHolderRefusalReadsAsPlainWords(t *testing.T) {
	got := humanizeReason(errors.New("not_holder:studio:admin"))
	if got != "held by studio:admin — only the holder can close it" {
		t.Fatalf("humanizeReason(not_holder) = %q", got)
	}
}
