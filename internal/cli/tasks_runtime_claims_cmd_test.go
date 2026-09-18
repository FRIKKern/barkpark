package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// The specimen, verbatim from the live ledger on 2026-09-18: row
// tlv-bl-events-actor-attribution, acceptance_criteria[0], lifecycle done,
// met true — and refuted the same day by two probes against production.
const (
	rcSpecimenCriterion = "A task.closed / task.claimed event carries the actor attribution (worker + epoch, or closed_by) so an auditor reconstructs close provenance from the event stream alone; a test asserts the emitted event includes these fields."
	rcSpecimenEvidence  = "PR #17209 merged 96e5a679ef528d3d71645da2cbc1ca5823144f93 (ancestor of origin/main). Internal.actor_stamp/2 is merged onto task.claimed (claim.ex:538) and task.closed (close.ex:652). Verified on origin/main by lead-cli-r4: git grep actor_stamp origin/main hits claim.ex:17,538,608."
)

func rcDetail(id, lifecycle, closedBy string, items ...taskboard.CriterionItem) taskboard.TaskDetail {
	d := taskboard.TaskDetail{ClosedBy: closedBy}
	d.DocID = id
	d.Lifecycle = lifecycle
	d.CriteriaItems = items
	return d
}

func rcIndex(ds ...taskboard.TaskDetail) taskboard.DetailIndex {
	ix := taskboard.DetailIndex{}
	for _, d := range ds {
		ix[d.DocID] = d
	}
	return ix
}

func rcSeal() taskboard.CriterionItem {
	return taskboard.CriterionItem{Met: true, Criterion: rcSpecimenCriterion, Evidence: rcSpecimenEvidence}
}

func rcRepoLocal() taskboard.CriterionItem {
	return taskboard.CriterionItem{Met: true, Criterion: "The deprecated helper is deleted.", Evidence: "PR #18004 merged, ancestor of origin/main."}
}

// TestRuntimeClaims_SpecimenIsFoundEndToEnd drives the whole live path — index
// to findings to verdict — on the row that motivated the detector. This is the
// arm that reds when the detector is reverted.
func TestRuntimeClaims_SpecimenIsFoundEndToEnd(t *testing.T) {
	ix := rcIndex(
		rcDetail("tlv-bl-events-actor-attribution", "done", "lead-cli-r2", rcSeal(), rcRepoLocal()),
		rcDetail("clean-row", "done", "lead-cli-r2", rcRepoLocal()),
	)
	findings, _ := runtimeClaimsOf(ix)

	if len(findings) != 1 {
		t.Fatalf("want exactly 1 finding, got %d: %+v", len(findings), findings)
	}
	f := findings[0]
	if f.Ref() != "tlv-bl-events-actor-attribution#0" {
		t.Fatalf("ref = %q, want the specimen's criterion 0", f.Ref())
	}
	if f.Verdict != taskboard.VerdictUnmeasured {
		t.Fatalf("verdict = %v, want UNMEASURED", f.Verdict)
	}
	if f.ClosedBy != "lead-cli-r2" {
		t.Fatalf("closed_by = %q — the finding must carry the confound axis for the reader", f.ClosedBy)
	}
}

// TestRuntimeClaims_QuietOnACleanLedger is the other direction. A ledger whose
// runtime claims all cite a live probe must produce NO findings — without this
// arm the suite would be green against a detector that flags everything.
func TestRuntimeClaims_QuietOnACleanLedger(t *testing.T) {
	probed := taskboard.CriterionItem{
		Met:       true,
		Criterion: rcSpecimenCriterion,
		Evidence:  "curl https://guerrilla.barkpark.cloud/v1/tasks/events?doc_id=x returned 200; every event carried actor_kind=worker. " + rcSpecimenEvidence,
	}
	ix := rcIndex(
		rcDetail("a", "done", "w1", probed, rcRepoLocal()),
		rcDetail("b", "done", "w2", probed, rcRepoLocal()),
	)
	findings, _ := runtimeClaimsOf(ix)
	if len(findings) != 0 {
		t.Fatalf("a ledger whose runtime claims are all probed must produce no findings; got %+v", findings)
	}
}

// TestRuntimeClaims_ExitsZeroAndNeverSaysFalse pins the two contract terms a
// consumer relies on: the command is advisory (a finding is a measurement, not
// a failure), and its verdict vocabulary never asserts the property is absent.
// Saying "false" is the exact overreach the detector exists to avoid.
func TestRuntimeClaims_ExitsZeroAndNeverSaysFalse(t *testing.T) {
	ix := rcIndex(rcDetail("tlv-bl-events-actor-attribution", "done", "w1", rcSeal()))
	findings, v := runtimeClaimsOf(ix)

	var so, se bytes.Buffer
	out := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := renderRuntimeClaims(out, findings, v); code != exitOK {
		t.Fatalf("exit = %d, want %d — a finding is advisory, not a command failure", code, exitOK)
	}
	body := so.String()
	if !strings.Contains(body, "UNMEASURED") {
		t.Fatalf("report must carry the UNMEASURED verdict word; got:\n%s", body)
	}
	for _, banned := range []string{"FALSE-DONE", "is false", "refuted"} {
		if strings.Contains(body, banned) {
			t.Fatalf("report says %q — the detector cannot know that; it measured the EVIDENCE, not the property.\n%s", banned, body)
		}
	}
	if !strings.Contains(body, "tlv-bl-events-actor-attribution#0") {
		t.Fatalf("report must print the ids to adjudicate; got:\n%s", body)
	}
	if !strings.Contains(body, "INDIVIDUALLY") {
		t.Fatalf("report must warn against a bulk flip; got:\n%s", body)
	}
}

// TestRuntimeClaims_ControlRidesAlong asserts the report cannot quote a
// marginal enrichment without the controlled one beside it, and that a
// NO MEASUREMENT control does not silently retract the per-row findings.
func TestRuntimeClaims_ControlRidesAlong(t *testing.T) {
	// Nobody anywhere cites a probe: the class comparison is arithmetic on a
	// constant and must refuse, while the per-row findings still stand.
	var ds []taskboard.TaskDetail
	for _, id := range []string{"a", "b", "c", "d"} {
		ds = append(ds, rcDetail(id, "done", "w1", rcSeal(), rcRepoLocal()))
	}
	findings, v := runtimeClaimsOf(rcIndex(ds...))

	if v.Discriminates || v.Survives {
		t.Fatalf("no row cites a probe; the control must refuse. got %+v", v)
	}
	if len(findings) != 4 {
		t.Fatalf("the control's refusal must NOT suppress the per-row findings; got %d want 4", len(findings))
	}
	word := runtimeControlWord(v)
	if !strings.Contains(word, "NO MEASUREMENT") {
		t.Fatalf("control word = %q, want the NO MEASUREMENT refusal", word)
	}
	if !strings.Contains(word, "per-row findings still stand") {
		t.Fatalf("control word = %q — it must say the refusal is class-level only", word)
	}
}

// TestRuntimeClaims_ControlWordsAreDistinct: the refusals mean different things
// and a reader who conflates them has lost the measurement.
func TestRuntimeClaims_ControlWordsAreDistinct(t *testing.T) {
	seen := map[string]string{}
	cases := map[string]taskboard.EnrichmentVerdict{
		"nomeasure": taskboard.ControlEnrichment(nil, taskboard.ClassRuntimeClaim, taskboard.ClassRepoLocalClaim, 2),
		"uncontrolled": taskboard.ControlEnrichment([]taskboard.EnrichmentRow{
			{ID: "a", Class: taskboard.ClassRuntimeClaim, Stratum: "w1", Missing: true},
			{ID: "b", Class: taskboard.ClassRuntimeClaim, Stratum: "w1", Missing: true},
			{ID: "c", Class: taskboard.ClassRepoLocalClaim, Stratum: "w2"},
			{ID: "d", Class: taskboard.ClassRepoLocalClaim, Stratum: "w2"},
		}, taskboard.ClassRuntimeClaim, taskboard.ClassRepoLocalClaim, 2),
		"survives": taskboard.ControlEnrichment([]taskboard.EnrichmentRow{
			{ID: "a", Class: taskboard.ClassRuntimeClaim, Stratum: "w1", Missing: true},
			{ID: "b", Class: taskboard.ClassRuntimeClaim, Stratum: "w1", Missing: true},
			{ID: "c", Class: taskboard.ClassRepoLocalClaim, Stratum: "w1"},
			{ID: "d", Class: taskboard.ClassRepoLocalClaim, Stratum: "w1"},
		}, taskboard.ClassRuntimeClaim, taskboard.ClassRepoLocalClaim, 2),
	}
	for name, v := range cases {
		w := runtimeControlWord(v)
		if prev, dup := seen[w]; dup {
			t.Fatalf("%s and %s both render %q", prev, name, w)
		}
		seen[w] = name
	}
	if len(seen) != 3 {
		t.Fatalf("got %d distinct control words, want 3", len(seen))
	}
}

// TestRuntimeClaims_NonTerminalRowsAreDropped asserts the SETUP, not only the
// verdict: the control arm proves the identical criterion IS found on a
// terminal row, so the empty result is the filter firing rather than the
// predicate failing.
func TestRuntimeClaims_NonTerminalRowsAreDropped(t *testing.T) {
	done, _ := runtimeClaimsOf(rcIndex(rcDetail("r", "done", "w1", rcSeal())))
	if len(done) != 1 {
		t.Fatalf("control: the terminal row must be found, got %d", len(done))
	}
	for _, lifecycle := range []string{"open", "in_progress", "blocked"} {
		got, _ := runtimeClaimsOf(rcIndex(rcDetail("r", lifecycle, "w1", rcSeal())))
		if len(got) != 0 {
			t.Fatalf("lifecycle %q is not terminal; want no finding, got %+v", lifecycle, got)
		}
	}
}

// TestRuntimeClaims_RejectsPositionalArguments keeps the verb's surface honest:
// a typo'd row id must not be silently read as "audit everything".
func TestRuntimeClaims_RejectsPositionalArguments(t *testing.T) {
	var so, se bytes.Buffer
	out := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runTaskRuntimeClaims(out, globals{}, manifest.Context{}, []string{"some-row"}); code == exitOK {
		t.Fatalf("a positional argument must be a usage error, got exit %d", code)
	}
}

// TestRuntimeClaims_NoEffectIsNotCalledConfounded is the live ledger's own
// shape, and the arm that keeps a true number from carrying a false story.
//
// On production 2026-09-18 the marginal ratio is 0.95x: runtime claims are
// proved with a live probe slightly MORE often than repo-local ones. There is
// no enrichment. Reporting that as CONFOUNDED would tell a reader an effect
// existed and was merely mis-attributed to the class — it never existed, and
// "the absence tracks the closing worker" is an explanation of nothing.
func TestRuntimeClaims_NoEffectIsNotCalledConfounded(t *testing.T) {
	// Suspect misses LESS than baseline, inside a single comparable stratum:
	// marginal < 1, comparable > 0, field discriminates.
	rows := []taskboard.EnrichmentRow{
		{ID: "r1", Class: taskboard.ClassRuntimeClaim, Stratum: "w1", Missing: true},
		{ID: "r2", Class: taskboard.ClassRuntimeClaim, Stratum: "w1"},
		{ID: "b1", Class: taskboard.ClassRepoLocalClaim, Stratum: "w1", Missing: true},
		{ID: "b2", Class: taskboard.ClassRepoLocalClaim, Stratum: "w1", Missing: true},
	}
	v := taskboard.ControlEnrichment(rows, taskboard.ClassRuntimeClaim, taskboard.ClassRepoLocalClaim, 2)

	// Setup assertions: without these the arm could pass on a verdict that
	// never reached the branch under test.
	if !v.Discriminates {
		t.Fatalf("setup: the field must discriminate here (%s)", v.Reason)
	}
	if v.Comparable != 1 {
		t.Fatalf("setup: want exactly 1 comparable stratum, got %d", v.Comparable)
	}
	if got := v.MarginalRatio(); got > 1 {
		t.Fatalf("setup: want a marginal ratio <= 1 (the live shape), got %.2fx", got)
	}

	word := runtimeControlWord(v)
	if strings.Contains(word, "CONFOUNDED") {
		t.Fatalf("a marginal ratio of %.2fx has no effect to confound; word = %q", v.MarginalRatio(), word)
	}
	if !strings.Contains(word, "NO EFFECT") {
		t.Fatalf("control word = %q, want the NO EFFECT reading", word)
	}
}
