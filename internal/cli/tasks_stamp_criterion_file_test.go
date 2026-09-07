package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// hazardCriterion is a criterion in the shape the ledger actually stores:
// MARKDOWN, with a backticked code span and a $VAR in the prose. Both of those
// are inert data to bp and to a file; both are ACTIVE syntax inside a
// double-quoted bash/zsh argument.
const hazardCriterion = "`echo HAZARD-FIRED` passes for the touched files, and $BP_STAMP_PROBE stays literal."

// TestCriterionTextThroughAShellIsAltered is ARM ONE — the hazard itself.
//
// It reconstructs the documented recipe's argument form:
//
//	bp task stamp … --criterion-text "<the exact stored wording>"
//
// by handing bash the same double-quoted token, and asserts the argument that
// arrives is NOT the criterion: the backticked code span RAN, its stdout was
// spliced in, and $BP_STAMP_PROBE was expanded. This is the measured defect
// (task-6576859f2c12a8e8) and it is a property of the shell, so it holds with
// or without any change to bp — it is what the file/stdin door exists to route
// around, and ARM TWO below is the half that reds if that door is removed.
func TestCriterionTextThroughAShellIsAltered(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skipf("no bash on PATH: %v", err)
	}
	// `printf %s "<criterion>"` is the minimal stand-in for bp's argv: whatever
	// the shell hands the child process is what bp would have received.
	script := `printf %s "` + hazardCriterion + `"`
	cmd := exec.Command(bash, "-c", script)
	cmd.Env = append(os.Environ(), "BP_STAMP_PROBE=EXPANDED-BY-THE-SHELL")
	got, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash -c failed: %v", err)
	}
	arrived := string(got)
	if arrived == hazardCriterion {
		t.Fatalf("the shell did NOT alter the criterion — the premise of this task is refuted:\n%q", arrived)
	}
	if !strings.Contains(arrived, "HAZARD-FIRED") {
		t.Fatalf("expected the backticked code span to be EXECUTED and its output spliced in, got:\n%q", arrived)
	}
	if strings.Contains(arrived, "$BP_STAMP_PROBE") {
		t.Fatalf("expected $BP_STAMP_PROBE to be expanded away by the shell, got:\n%q", arrived)
	}
	if strings.Contains(arrived, "`") {
		t.Fatalf("expected the backticks to be consumed by command substitution, got:\n%q", arrived)
	}
}

// TestCriterionTextFileDeliversBytesIdentically is ARM TWO — the door closed.
// The SAME criterion, through --criterion-text-file, reaches the POST byte for
// byte. Remove the file/stdin path and this test cannot compile or cannot find
// the rewritten flag: it is the arm that reds on the mutation.
func TestCriterionTextFileDeliversBytesIdentically(t *testing.T) {
	path := filepath.Join(t.TempDir(), "crit.txt")
	// The obvious way to produce this file is `… | jq -r '…' > crit.txt`, which
	// appends exactly one newline. Reproduce that, so the assertion covers the
	// real shape and not a hand-tuned one.
	if err := os.WriteFile(path, []byte(hazardCriterion+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tail := []string{"task-1", "worker", "1", "--criterion", "0", "--criterion-text-file", path, "--met", "--evidence", "e"}
	got, err := resolveCriterionTextFile(tail)
	if err != nil {
		t.Fatalf("resolveCriterionTextFile: %v", err)
	}
	want := "--criterion-text=" + hazardCriterion
	if !containsExact(got, want) {
		t.Fatalf("the criterion did not survive byte-identical.\nwant token: %q\ngot tail:   %q", want, got)
	}
	// And the rest of the invocation is untouched, in order.
	if strings.Join(got, "\x00") != strings.Join([]string{
		"task-1", "worker", "1", "--criterion", "0", want, "--met", "--evidence", "e",
	}, "\x00") {
		t.Fatalf("the tail was reordered or lost tokens: %q", got)
	}
}

// TestCriterionTextFromStdinDeliversBytesIdentically covers the `-` arm: the
// same guarantee without a temp file, for a pipeline that never touches disk.
func TestCriterionTextFromStdinDeliversBytesIdentically(t *testing.T) {
	orig := stampStdin
	t.Cleanup(func() { stampStdin = orig })
	stampStdin = strings.NewReader(hazardCriterion + "\n")

	got, err := resolveCriterionTextFile([]string{"--criterion", "0", "--criterion-text-file", "-"})
	if err != nil {
		t.Fatalf("resolveCriterionTextFile: %v", err)
	}
	if !containsExact(got, "--criterion-text="+hazardCriterion) {
		t.Fatalf("stdin did not deliver the criterion byte-identical: %q", got)
	}
}

// TestCriterionTextFileNewlineHandling pins the ONE rule that could quietly
// corrupt the guard text: exactly one trailing newline is stripped, and every
// interior newline survives. A multi-line criterion is precisely the shape the
// shell path could not carry safely.
func TestCriterionTextFileNewlineHandling(t *testing.T) {
	multi := "first line\n\nthird line, with a `code span`"
	for _, tc := range []struct {
		name, written, want string
	}{
		{"no trailing newline", multi, multi},
		{"one trailing newline", multi + "\n", multi},
		{"crlf trailing newline", multi + "\r\n", multi},
		{"two trailing newlines keep one", multi + "\n\n", multi + "\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "crit.txt")
			if err := os.WriteFile(path, []byte(tc.written), 0o600); err != nil {
				t.Fatal(err)
			}
			got, err := resolveCriterionTextFile([]string{"--criterion-text-file", path})
			if err != nil {
				t.Fatalf("resolveCriterionTextFile: %v", err)
			}
			if !containsExact(got, "--criterion-text="+tc.want) {
				t.Fatalf("want %q, got tail %q", tc.want, got)
			}
		})
	}
}

// TestCriterionTextFileRefusals: every way the new door can be misused fails
// LOUDLY and forwards nothing. A stamp that cannot read its own guard text must
// never fall through to an unguarded write.
func TestCriterionTextFileRefusals(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "crit.txt")
	if err := os.WriteFile(good, []byte(hazardCriterion), 0o600); err != nil {
		t.Fatal(err)
	}
	empty := filepath.Join(dir, "empty.txt")
	if err := os.WriteFile(empty, []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name string
		tail []string
		want string
	}{
		{"both doors", []string{"--criterion-text", "x", "--criterion-text-file", good}, "not both"},
		{"both doors, reversed", []string{"--criterion-text-file", good, "--criterion-text", "x"}, "not both"},
		{"no path", []string{"--criterion-text-file", "--met"}, "needs a path"},
		{"path at the end", []string{"--criterion", "0", "--criterion-text-file"}, "needs a path"},
		{"empty inline path", []string{"--criterion-text-file="}, "empty path"},
		{"missing file", []string{"--criterion-text-file", filepath.Join(dir, "nope.txt")}, "reading the criterion wording from"},
		{"empty file", []string{"--criterion-text-file", empty}, "is empty"},
		{"passed twice", []string{"--criterion-text-file", good, "--criterion-text-file", good}, "passed twice"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveCriterionTextFile(tc.tail)
			if err == nil {
				t.Fatalf("expected a refusal, got tail %q", got)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("refusal does not say %q:\n%s", tc.want, err.Error())
			}
			if got != nil {
				t.Fatalf("a refusal forwarded a tail: %q", got)
			}
		})
	}
}

// TestCriterionTextInlineFormUntouched is the backward-compatibility fence:
// a tail carrying only the ORIGINAL --criterion-text is returned unchanged,
// token for token. The new door is a door BESIDE the old one.
func TestCriterionTextInlineFormUntouched(t *testing.T) {
	tail := []string{"task-1", "w", "1", "--criterion", "0", "--criterion-text", "plain wording", "--met"}
	got, err := resolveCriterionTextFile(tail)
	if err != nil {
		t.Fatalf("resolveCriterionTextFile: %v", err)
	}
	if strings.Join(got, "\x00") != strings.Join(tail, "\x00") {
		t.Fatalf("the classic form was rewritten:\nwant %q\ngot  %q", tail, got)
	}
}

// TestCriteriaMismatchRefusalNamesShellEvaluation is criterion 2 of the row:
// the refusal must offer the second candidate cause, not send the operator to
// re-check an index that was right all along.
func TestCriteriaMismatchRefusalNamesShellEvaluation(t *testing.T) {
	var so, se bytes.Buffer
	explainCriteriaMismatch(newWriter(&so, &se), hazardCriterion, false)
	got := se.String()
	for _, want := range []string{
		"SHELL EVALUATION",
		"COMMAND SUBSTITUTION",
		"--criterion-text-file",
		"0-BASED", // the pre-existing off-by-one hint is kept BESIDE the new one
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("mismatch hint does not mention %q:\n%s", want, got)
		}
	}
	if so.Len() != 0 {
		t.Fatalf("the hint wrote to stdout, which must stay one parseable document:\n%s", so.String())
	}
}

// …and when the wording came off disk, the hint RULES THAT CAUSE OUT rather
// than offering a remedy already in use. A hint that says "maybe your shell"
// to someone who used no shell is the same wild goose chase, one step over.
func TestCriteriaMismatchRefusalRulesOutShellWhenTextCameFromAFile(t *testing.T) {
	var so, se bytes.Buffer
	explainCriteriaMismatch(newWriter(&so, &se), hazardCriterion, true)
	got := se.String()
	if !strings.Contains(got, "RULED OUT") {
		t.Fatalf("hint does not rule shell evaluation out for a file-sourced stamp:\n%s", got)
	}
	if strings.Contains(got, "fix — stop sending the wording through a shell") {
		t.Fatalf("hint offers the remedy the caller already used:\n%s", got)
	}
}

func TestCriteriaMismatchReasonMatchesCompoundCodes(t *testing.T) {
	for _, code := range []string{"criteria_mismatch", "criteria_mismatch:3"} {
		if !criteriaMismatchReason(code) {
			t.Fatalf("%q should be recognized as a text mismatch", code)
		}
	}
	for _, code := range []string{"", "criteria_unmet", "criterion_text_required"} {
		if criteriaMismatchReason(code) {
			t.Fatalf("%q must NOT be treated as a text mismatch", code)
		}
	}
}

// TestStampHelpAdvertisesTheNonEvaluatingDoor — criterion 4's `--help` half.
// The flag is client-side and undeclarable, so nothing but this block can
// surface it, and a door nobody can find leaves the shell recipe as the only
// one anybody knows.
func TestStampHelpAdvertisesTheNonEvaluatingDoor(t *testing.T) {
	var so, se bytes.Buffer
	usageCommand(newWriter(&so, &se), manifest.Command{
		ID: taskStampCommandID, Noun: "task", Verb: "stamp", Summary: "stamp a criterion",
	})
	got := se.String()
	for _, want := range []string{"--criterion-text-file <path>", "stdin", "COMMAND SUBSTITUTION"} {
		if !strings.Contains(got, want) {
			t.Fatalf("`bp task stamp --help` does not mention %q:\n%s", want, got)
		}
	}

	// …and no OTHER verb advertises a flag its parser would refuse.
	var so2, se2 bytes.Buffer
	usageCommand(newWriter(&so2, &se2), manifest.Command{ID: taskGetCommandID, Noun: "task", Verb: "get"})
	if strings.Contains(se2.String(), "--criterion-text-file") {
		t.Fatalf("`bp task get` help advertises a flag it does not take:\n%s", se2.String())
	}
}

func TestStampTextCameFromFile(t *testing.T) {
	if !stampTextCameFromFile([]string{"--criterion-text-file", "x"}) {
		t.Fatal("space form not detected")
	}
	if !stampTextCameFromFile([]string{"--criterion-text-file=x"}) {
		t.Fatal("inline form not detected")
	}
	if stampTextCameFromFile([]string{"--criterion-text", "x"}) {
		t.Fatal("the classic flag must not read as the file door")
	}
}

func containsExact(tokens []string, want string) bool {
	for _, tk := range tokens {
		if tk == want {
			return true
		}
	}
	return false
}
