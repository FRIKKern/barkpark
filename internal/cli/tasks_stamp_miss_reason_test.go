package cli

import (
	"strings"
	"sync/atomic"
	"testing"
)

// THE REGRESSION ARM for task-1cbed3f46cac8106, and it proves BOTH directions in
// ONE run, because the defect is exactly that the two directions were reported
// identically.
//
// The measured defect: a `--miss` write lands its reason at
// acceptance_criteria[N].attempts[].note and NEVER touches `evidence`, while the
// verb's own read-back line said "evidence <empty>". So a landed miss and a
// dropped write printed the same sentence, and every readback keyed on
// `.evidence|length` reported a confident zero for a write that was perfect.
// The companion hole: `--miss --evidence <text>` was refused by NOBODY when a
// --note rode along — the server's `miss ->` branch reads "note" and never looks
// at "evidence" — so the text was discarded behind a 2xx.
//
// ARM 1 (the read-back tells the truth): a landed miss must name
// attempts[].note and quote the stored reason, and must NOT print the bare
// "evidence <empty>" line.
// ARM 2 (the wrong field is refused, and refused EARLY): `--miss --evidence` is
// refused before the "miss (attempt)" echo and before any POST fires.
// ARM 3 (the CONTROL): a `--met` row still reports `evidence N bytes`, so every
// existing caller keyed on .evidence for a MET criterion reads what it read
// before. Without this arm, deleting the whole evidence branch would pass.
//
// THE MUTATION that reds ARM 1: in storedCriterionSummary (tasks_stamp_cmd.go),
// delete the `else if n := len(stored.Attempts); n > 0 {` branch so `ev` stays
// "evidence <empty>" — i.e. restore the old .evidence-only readback.
func TestTaskStampMiss_ReasonIsReadBackFromAttemptsNoteAndEvidenceIsRefused(t *testing.T) {
	hits := stampTestServer(t)

	const reason = "the fixture never reaches the changed line, so the gate is vacuous"

	// ── ARM 1: a landed miss reads its reason back from the attempt trail ──
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--miss", "--note", reason,
	})
	if code != exitOK {
		t.Fatalf("ARM 1: exit = %d, want exitOK on a landed miss; out:\n%s", code, out)
	}
	if !strings.Contains(out, missReasonField) {
		t.Errorf("ARM 1: the read-back must name WHERE the reason landed (%q); got:\n%s", missReasonField, out)
	}
	if !strings.Contains(out, reason[:32]) {
		t.Errorf("ARM 1: the read-back must quote the stored reason; got:\n%s", out)
	}
	if strings.Contains(out, "evidence <empty>") {
		t.Errorf("ARM 1: a miss that stored a note must NOT report %q — that is the false zero this row exists to end; got:\n%s",
			"evidence <empty>", out)
	}
	after1 := atomic.LoadInt32(hits)
	if after1 != 1 {
		t.Fatalf("ARM 1: stamp POST fired %d times, want 1", after1)
	}

	// ── ARM 2: --miss --evidence is refused, BEFORE the echo and before the POST ──
	out2, code2 := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--miss", "--note", reason, "--evidence", "a proof a miss cannot carry",
	})
	if code2 != exitValidation {
		t.Fatalf("ARM 2: exit = %d, want exitValidation (%d) — --evidence on a miss is silently DROPPED by the server, so the CLI must refuse it; out:\n%s",
			code2, exitValidation, out2)
	}
	if !strings.Contains(out2, "--miss does not take --evidence") {
		t.Errorf("ARM 2: the refusal must say which field is wrong; got:\n%s", out2)
	}
	if !strings.Contains(out2, missReasonField) {
		t.Errorf("ARM 2: the refusal must name where the reason actually lands (%q); got:\n%s", missReasonField, out2)
	}
	if strings.Contains(out2, "miss (attempt)") {
		t.Errorf("ARM 2: the refusal must fire BEFORE the \"miss (attempt)\" progress line — a reader must never see a line implying the write is proceeding on a call about to be refused; got:\n%s", out2)
	}
	if n := atomic.LoadInt32(hits); n != after1 {
		t.Errorf("ARM 2: a refused stamp must send nothing; POST count moved %d -> %d", after1, n)
	}

	// ── ARM 2b: a note-less miss is refused by the CLI, also before the echo ──
	out3, code3 := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1", "--criterion", "2", "--miss",
	})
	if code3 != exitValidation {
		t.Fatalf("ARM 2b: exit = %d, want exitValidation; out:\n%s", code3, out3)
	}
	if strings.Contains(out3, "miss (attempt)") {
		t.Errorf("ARM 2b: the note refusal must fire BEFORE the \"miss (attempt)\" echo; got:\n%s", out3)
	}
	if !strings.Contains(out3, missReasonField) {
		t.Errorf("ARM 2b: the refusal must name where --note lands; got:\n%s", out3)
	}
	if n := atomic.LoadInt32(hits); n != after1 {
		t.Errorf("ARM 2b: a refused stamp must send nothing; POST count moved %d -> %d", after1, n)
	}

	// ── ARM 3 (CONTROL): a MET row still reports evidence by length ──
	out4, code4 := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "a normal row",
	})
	if code4 != exitOK {
		t.Fatalf("ARM 3: exit = %d, want exitOK; out:\n%s", code4, out4)
	}
	if !strings.Contains(out4, "evidence 10 bytes") {
		t.Errorf("ARM 3 (control): a MET row must still report its evidence by length — the miss branch must not have changed what an .evidence caller reads; got:\n%s", out4)
	}
}
