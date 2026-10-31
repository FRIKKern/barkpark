package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

func TestParseStampArgsReadsConfirmAmendment(t *testing.T) {
	sa, forward := parseStampArgs([]string{
		"t1", "reviewer", "0", "--criterion", "1",
		"--criterion-text", "new wording", "--confirm-amendment", "--note", "read it against the tests",
	}, "string")
	if !sa.confirm || sa.met || sa.miss || sa.withdraw || sa.amend {
		t.Fatalf("--confirm-amendment must parse as confirm and nothing else: %+v", sa)
	}
	if len(forward) != 10 {
		t.Fatalf("forward should carry every token, got %d: %v", len(forward), forward)
	}
	idx := 1
	if line := stampEchoLine(stampArgs{criterion: &idx, confirm: true}); !strings.Contains(line, "CONFIRM") {
		t.Fatalf("the echo must name the confirm: %q", line)
	}
}

func TestStampMismatchesConfirmVerdict(t *testing.T) {
	req := stampRequest{index: 0, text: "new wording", confirm: true, note: "read it against the tests"}

	landed := taskboard.CriterionItem{
		Criterion:     "new wording",
		Confirmations: []taskboard.CriterionAttempt{{Note: "read it against the tests", Worker: "reviewer"}},
	}
	if got := stampMismatches(req, landed); len(got) != 0 {
		t.Fatalf("a landed confirmation must be clean, got %v", got)
	}

	unsigned := taskboard.CriterionItem{Criterion: "new wording"}
	got := stampMismatches(req, unsigned)
	if !strings.Contains(strings.Join(got, " "), "no confirmation") {
		t.Fatalf("a confirm the store does not hold must not read as landed, got %v", got)
	}
}

func TestSecondEyesRefusalsAreValidation(t *testing.T) {
	for _, code := range []string{"amendment_unconfirmed", "self_confirmation", "nothing_to_confirm"} {
		if got := codeExit[code]; got != exitValidation {
			t.Errorf("%s exits %d, want %d: nothing moved under the caller and a resend cannot succeed", code, got, exitValidation)
		}
	}
}

func TestStampRequestOfReadsConfirmAmendment(t *testing.T) {
	cmd := stampCommandFixture(t)
	cmd.Flags = append(cmd.Flags, manifest.Flag{Name: "confirm-amendment", Type: "bool"})
	req, ok := stampRequestOf(cmd, []string{
		"bp-task-x", "reviewer", "0",
		"--criterion", "1", "--confirm-amendment", "--note", "read it", "--criterion-text", "new wording",
	})
	if !ok || !req.confirm || req.note != "read it" {
		t.Fatalf("the read-back must know it is confirming a confirm: ok=%v req=%+v", ok, req)
	}
}
