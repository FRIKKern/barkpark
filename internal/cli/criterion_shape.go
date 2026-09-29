package cli

import (
	"regexp"
	"sort"
	"strings"
)

// Criterion-shape triage lens.
//
// MEASURED LIMIT, STATED UP FRONT: this is a TRIAGE LENS, never a verdict.
// A 2026-08-24 hand sample of 80 criteria found 17.5% unverifiable while a
// keyword scan condemned 70.2% as instrument-free; a 2026-09-17 re-sample of
// 30 found 26.7% unverifiable (Wilson 95% CI 12.0%-44.1%). The lens therefore
// cannot gate anything, and nothing in the server gates on it either:
// Barkpark's satisfied?/1 reads lifecycle_status, never acceptance_criteria.
// Use CriterionShape to RANK rows for a human read, not to pass or fail them.

// CriterionShape is the set of structural signals found in one criterion's text.
type CriterionShape struct {
	// Positive signals (rubric rules R1-R5).
	HasCommand      bool // R1: a pasteable command
	HasPath         bool // R1: a repo path
	HasSymbol       bool // R1: a symbol/arity or Module.fun reference
	HasExactValue   bool // R2: a number, exit code, or quoted literal expectation
	HasFailureProof bool // R3: a mutation proof or negative control
	HasBothBranches bool // R4: the negative branch is disposed
	HasEnumeration  bool // R5: per-item disposition over a named set

	// Negative signals (rubric rules R4, R6, R7).
	BareConditional bool     // R4 violation: opens "If ..." with no negative branch
	VerdictWords    []string // R6 violation: adjectives a second reader can weigh differently
	IsInstruction   bool     // R7 violation: tells the reader what to do, names no state

	// Routing signal (rubric rule R8).
	NeedsLeadClose bool // wording says a lead/merge closes it; merge_gate:true belongs on the row
}

var (
	reCommand = regexp.MustCompile(`(?m)\b(mix test|go test|go vet|go build|curl |gh (pr|api|run) |bash scripts/|python3 scripts/|npm run|node --test|bp [a-z-]+ )`)
	rePath    = regexp.MustCompile(`\b(api|internal|cloud|scripts|docs|js|web|tooling|scaffy|deploy|test)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+`)
	reSymbol  = regexp.MustCompile(`\b([A-Z][A-Za-z0-9_]*\.[a-z_][A-Za-z0-9_]*(/\d)?|[a-z_][A-Za-z0-9_]*/\d)\b`)
	reValue   = regexp.MustCompile(`(?i)\b(exits? (0|1|[0-9]{1,3})|returns? (200|201|4\d\d|5\d\d)|== ?'|=== ?'|\b\d+(\.\d+)?\s?(byte|kib|mib|gb|mb|ms|s|minute|hour|row|line|call|run)s?\b|\b(zero|exactly \d+|0/\d+|\d+/\d+)\b)`)
	reFail    = regexp.MustCompile(`(?i)(mutation proof|negative control|shown? (it )?(fail|red)|proven able to fail|remove the fix|revert the fix|red arm|red before|fail closed|deliberately[- ](broken|planted)|does not count)`)
	reBranch  = regexp.MustCompile(`(?i)(if (it|the|that|this|investigation|no|any|none|fewer|a )[^.]{0,120}\b(instead|otherwise|that refutation|is recorded as the finding|the ruling is recorded)|either[^.]{0,80}\bor\b|both arms|both directions|whichever (ships|outcome|of)|refutation discharges|or (explicitly )?(left|recorded) with a reason)`)
	reEnum    = regexp.MustCompile(`(?i)(every (row|call site|item|one|case|entry)|each (of the|is (classified|disposed))|per-item|all \d+ [a-z]|the seven|enumerate)`)
	reInstr   = regexp.MustCompile(`(?i)^\s*(READ|GO|START|DECIDE|FIRST,|WHOEVER TAKES THIS|BEFORE ANYTHING ELSE)\b|whoever (takes|claims) this row (starts|must|should)`)
	reLead    = regexp.MustCompile(`(?i)(LEAD[- ]?(GATED|CLOSES)|the lead closes|MERGE[- ]GATED|LEAD closes)`)
	// R6: verdict words. Matched as whole words so "cleanly" and "consistently" are caught
	// by their stems but "clean run" in a named command is not spared either — the lens
	// over-fires by design and the human read is the verdict.
	verdictWords = []string{"honest", "clean", "cleanly", "robust", "acceptable", "reasonable",
		"sensible", "sane", "appropriate", "properly", "correctly", "consistently",
		"consistent with", "graceful", "gracefully", "adequate", "sufficiently", "nicely", "good enough"}
	reVerdict = regexp.MustCompile(`(?i)\b(` + strings.Join(verdictWords, "|") + `)\b`)
	// A bare conditional: opens with If/Once/When/Should and never disposes the other side.
	reOpensCond = regexp.MustCompile(`(?i)^\s*(if|once|when|should)\b`)
)

// ClassifyCriterion runs the triage lens over one criterion's text.
//
// @canonical capability:criterion-shape-triage aka:criterion-lint,acceptance-criteria-rubric doc:docs/setup/TASK-SYSTEM.md
func ClassifyCriterion(text string) CriterionShape {
	s := CriterionShape{
		HasCommand:      reCommand.MatchString(text),
		HasPath:         rePath.MatchString(text),
		HasSymbol:       reSymbol.MatchString(text),
		HasExactValue:   reValue.MatchString(text),
		HasFailureProof: reFail.MatchString(text),
		HasBothBranches: reBranch.MatchString(text),
		HasEnumeration:  reEnum.MatchString(text),
		IsInstruction:   reInstr.MatchString(text),
		NeedsLeadClose:  reLead.MatchString(text),
	}
	if reOpensCond.MatchString(text) && !s.HasBothBranches {
		s.BareConditional = true
	}
	seen := map[string]bool{}
	for _, m := range reVerdict.FindAllString(text, -1) {
		w := strings.ToLower(m)
		if !seen[w] {
			seen[w] = true
			s.VerdictWords = append(s.VerdictWords, w)
		}
	}
	sort.Strings(s.VerdictWords)
	return s
}

// HasNamedInstrument reports rule R1: the criterion names a path, a symbol, or a command.
func (s CriterionShape) HasNamedInstrument() bool {
	return s.HasCommand || s.HasPath || s.HasSymbol
}

// Concerns lists only POSITIVE detections — a defect the lens actually SAW in the
// text (R7, R4, R6, R8). An absence is deliberately NOT a concern: the 2026-09-17
// re-measurement found the absence signals fire on 23/30 real criteria while hand
// judgement called 22/30 checkable, so "no path matched" is evidence of nothing.
// Absences are reported separately by Absences and rank rows for a human read.
func (s CriterionShape) Concerns() []string {
	var out []string
	if s.IsInstruction {
		out = append(out, "R7 instruction-not-state")
	}
	if s.BareConditional {
		out = append(out, "R4 one-sided-conditional")
	}
	if len(s.VerdictWords) > 0 {
		out = append(out, "R6 verdict-word:"+strings.Join(s.VerdictWords, ","))
	}
	if s.NeedsLeadClose {
		out = append(out, "R8 needs-merge-gate-flag")
	}
	return out
}

// Absences lists rubric signals the lens did NOT find. Advisory only: measured
// over 30 live criteria, "R1 no-named-instrument" fired on 23 while hand
// judgement found 8 unverifiable. Rank with it; never gate on it.
func (s CriterionShape) Absences() []string {
	var out []string
	if !s.HasNamedInstrument() {
		out = append(out, "R1 no-named-instrument")
	}
	if !s.HasExactValue {
		out = append(out, "R2 no-expected-value")
	}
	if !s.HasFailureProof {
		out = append(out, "R3 no-failure-proof")
	}
	return out
}
