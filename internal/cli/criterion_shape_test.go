package cli

import (
	"encoding/json"
	"os"
	"testing"
)

type criterionFixture struct {
	ID            string `json:"id"`
	TaskID        string `json:"task_id"`
	Index         int    `json:"index"`
	HandCheckable bool   `json:"hand_checkable"`
	Criterion     string `json:"criterion"`
}

func loadCriterionCorpus(t *testing.T) []criterionFixture {
	t.Helper()
	b, err := os.ReadFile("testdata/criterion_shape_corpus.json")
	if err != nil {
		t.Fatalf("read corpus: %v", err)
	}
	var out []criterionFixture
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("parse corpus: %v", err)
	}
	if len(out) != 30 {
		t.Fatalf("corpus size = %d, want 30 (the recorded 2026-09-17 sample)", len(out))
	}
	return out
}

// TestClassifyCriterionSyntheticArms pins each signal against a minimal case AND
// its negative twin, so a regex that matches everything (or nothing) fails here.
func TestClassifyCriterionSyntheticArms(t *testing.T) {
	cases := []struct {
		name  string
		text  string
		check func(CriterionShape) bool
		want  bool
	}{
		{"command-hit", "Gate green: cd api && mix test test/foo_test.exs", CriterionShape.HasNamedInstrument, true},
		{"command-miss", "The thing works well afterwards", CriterionShape.HasNamedInstrument, false},
		{"path-hit", "internal/cli/destroy_confirm.go gains two entries", CriterionShape.HasNamedInstrument, true},
		{"value-hit", "the reader exits 0 with MISSES 0", func(s CriterionShape) bool { return s.HasExactValue }, true},
		{"value-miss", "peak heap is bounded or streamed", func(s CriterionShape) bool { return s.HasExactValue }, false},
		{"failproof-hit", "MUTATION PROOF: remove the fix and paste the RED", func(s CriterionShape) bool { return s.HasFailureProof }, true},
		{"failproof-miss", "A test covers the new entries", func(s CriterionShape) bool { return s.HasFailureProof }, false},
		{"branches-hit", "If investigation shows the defect does NOT exist, that REFUTATION discharges this criterion instead", func(s CriterionShape) bool { return s.HasBothBranches }, true},
		{"bare-conditional", "If confirmed, a Studio criterion text edit persists across a reload", func(s CriterionShape) bool { return s.BareConditional }, true},
		{"instruction-hit", "READ THE DOCUMENTED DECISION BEFORE ANYTHING ELSE", func(s CriterionShape) bool { return s.IsInstruction }, true},
		{"instruction-miss", "The refusal prints a remedy that works", func(s CriterionShape) bool { return s.IsInstruction }, false},
		{"verdict-hit", "renders an honest fallback", func(s CriterionShape) bool { return len(s.VerdictWords) > 0 }, true},
		{"verdict-miss", "the census returns 0 rows", func(s CriterionShape) bool { return len(s.VerdictWords) > 0 }, false},
		{"lead-hit", "MERGE-GATED (the LEAD closes this): the PR is merged to main", func(s CriterionShape) bool { return s.NeedsLeadClose }, true},
		{"lead-miss", "the builder closes after the gate is green", func(s CriterionShape) bool { return s.NeedsLeadClose }, false},
	}
	for _, c := range cases {
		if got := c.check(ClassifyCriterion(c.text)); got != c.want {
			t.Errorf("%s: got %v want %v for %q", c.name, got, c.want, c.text)
		}
	}
}

// TestClassifyCriterionRealShapeIsSplit is the broken-instrument guard.
//
// A uniform verdict is the signature of a broken instrument, and a selftest whose
// fixtures encode a shape the system never emits measures nothing. These 30 are
// VERBATIM live criteria drawn with random.Random(20260917).sample over the 2,763
// open-row criteria read from the ledger on 2026-09-17. The test asserts the lens
// SPLITS them on every axis that is supposed to discriminate.
func TestClassifyCriterionRealShapeIsSplit(t *testing.T) {
	corpus := loadCriterionCorpus(t)
	var instrument, value, failproof, branches, verdict, lead, concernFree int
	for _, f := range corpus {
		s := ClassifyCriterion(f.Criterion)
		if s.HasNamedInstrument() {
			instrument++
		}
		if s.HasExactValue {
			value++
		}
		if s.HasFailureProof {
			failproof++
		}
		if s.HasBothBranches {
			branches++
		}
		if len(s.VerdictWords) > 0 {
			verdict++
		}
		if s.NeedsLeadClose {
			lead++
		}
		if len(s.Concerns()) == 0 {
			concernFree++
		}
	}
	n := len(corpus)
	for _, ax := range []struct {
		name string
		hits int
	}{
		{"HasNamedInstrument", instrument},
		{"HasExactValue", value},
		{"HasFailureProof", failproof},
		{"HasBothBranches", branches},
		{"VerdictWords", verdict},
	} {
		if ax.hits == 0 || ax.hits == n {
			t.Errorf("axis %s is UNIFORM at %d/%d over real criteria — a uniform verdict is the signature of a broken instrument", ax.name, ax.hits, n)
		}
	}
	if lead == 0 {
		t.Errorf("NeedsLeadClose never fired over 30 real criteria; the R8 routing signal is inert")
	}
	if concernFree == 0 || concernFree == n {
		t.Errorf("Concerns() is uniform at %d/%d — the lens either condemns or clears everything", concernFree, n)
	}
	// The absence signals must ALSO split, and must be MORE trigger-happy than
	// hand judgement — that asymmetry is rule R9 in executable form.
	noInstrument := 0
	for _, f := range corpus {
		for _, a := range ClassifyCriterion(f.Criterion).Absences() {
			if a == "R1 no-named-instrument" {
				noInstrument++
			}
		}
	}
	handUnverifiable := 0
	for _, f := range corpus {
		if !f.HandCheckable {
			handUnverifiable++
		}
	}
	if noInstrument <= handUnverifiable {
		t.Errorf("R1 absence fired on %d/%d but hand judgement found only %d unverifiable; if the keyword scan ever stops over-firing, re-measure before trusting it", noInstrument, n, handUnverifiable)
	}
	t.Logf("R9 in numbers: R1-absence %d/%d vs hand-unverifiable %d/%d", noInstrument, n, handUnverifiable, n)
	t.Logf("real-shape distribution over n=%d: instrument=%d value=%d failproof=%d branches=%d verdict=%d lead=%d concern-free=%d",
		n, instrument, value, failproof, branches, verdict, lead, concernFree)
}

// TestClassifyCriterionUnderperformsHandJudgement pins rubric rule R9 as an
// EXECUTABLE fact rather than a sentence: the keyword lens disagrees with hand
// judgement often enough that it must never be a gate. If someone tightens the
// regexes until the lens agrees with hand judgement on this corpus, they have
// overfit 30 rows, and this test says so.
func TestClassifyCriterionUnderperformsHandJudgement(t *testing.T) {
	corpus := loadCriterionCorpus(t)
	agree := 0
	for _, f := range corpus {
		lensSaysCheckable := len(ClassifyCriterion(f.Criterion).Concerns()) == 0
		if lensSaysCheckable == f.HandCheckable {
			agree++
		}
	}
	t.Logf("lens agrees with hand judgement on %d/%d (%.1f%%)", agree, len(corpus), 100*float64(agree)/float64(len(corpus)))
	if agree == len(corpus) {
		t.Errorf("lens agrees with hand judgement on 30/30 — either the regexes were overfit to this corpus or the hand labels were derived from the lens; R9 says a keyword scan is a triage lens, never a verdict")
	}
}
