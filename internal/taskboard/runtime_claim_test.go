package taskboard

import (
	"strings"
	"testing"
)

// The specimen, verbatim from the live ledger on 2026-09-18. Row
// tlv-bl-events-actor-attribution, acceptance_criteria[0]: lifecycle_status
// done, met true, and refuted by two probes against production the same day —
// the per-doc event stream's key union over 152 events is exactly
// [at doc_id event id rev], and all 16 document revisions answer actor_* null.
//
// The evidence is quoted rather than paraphrased because paraphrasing it is how
// a fixture stops reproducing the shape the system actually emits. Every clause
// in it is TRUE; none of them is a live observation.
const (
	specimenCriterion = "A task.closed / task.claimed event carries the actor attribution (worker + epoch, or closed_by) so an auditor reconstructs close provenance from the event stream alone; a test asserts the emitted event includes these fields."
	specimenEvidence  = "PR #17209 merged 96e5a679ef528d3d71645da2cbc1ca5823144f93 (ancestor of origin/main). Internal.actor_stamp/2 ({worker, epoch}) is merged onto task.claimed (claim.ex:538 do_claim, :608 do_renew) and task.closed (close.ex:652, epoch read from the row AS WRITTEN; a claimless close names the caller and no epoch); closed_by kept. Detector api/test/barkpark/tasks/events_actor_attribution_test.exs (11 arms). Verified on origin/main by lead-cli-r4: git grep actor_stamp origin/main -- api/lib/barkpark/tasks hits claim.ex:17,538,608 and close.ex:85,652."
)

// TestSpecimenClassifiesUnmeasured is the arm that REDS when the detector is
// reverted. It runs the predicate against the exact row that motivated it.
//
// Reversion proof: deleting the "emitted|emits|the event stream|event carries"
// alternation from runtimeSurfacePatterns makes AssertsRuntimeProperty return
// false here and this test reports
// "got not-a-runtime-claim, want UNMEASURED-AT-RUNTIME".
func TestSpecimenClassifiesUnmeasured(t *testing.T) {
	got := ClassifyCriterion(CriterionItem{
		Criterion: specimenCriterion,
		Met:       true,
		Evidence:  specimenEvidence,
	})
	if got != VerdictUnmeasured {
		t.Fatalf("the specimen must classify as unmeasured-at-runtime; got %v, want %v", got, VerdictUnmeasured)
	}
}

// TestSpecimenPartsEachCarryTheirHalf pins WHY the specimen classifies, so a
// future edit that keeps the verdict for the wrong reason is still caught. A
// verdict that survives because an unrelated pattern started matching is not
// the same detector.
func TestSpecimenPartsEachCarryTheirHalf(t *testing.T) {
	if !AssertsRuntimeProperty(specimenCriterion) {
		t.Errorf("specimen criterion must read as a runtime claim")
	}
	if EvidenceCitesLiveProbe(specimenEvidence) {
		t.Errorf("specimen evidence cites NO live probe; a pattern that matches it has widened too far")
	}
	if !EvidenceCitesCodePresence(specimenEvidence) {
		t.Errorf("specimen evidence is repo-side proof and must read as code presence")
	}
}

// TestQuietArms is the other half of the quality bar: the cases where the
// detector must stay SILENT. Each of these would put a clean row on a human's
// adjudication list, which is the expensive error.
func TestQuietArms(t *testing.T) {
	cases := []struct {
		name string
		item CriterionItem
		want RuntimeVerdict
	}{
		{
			// A repo-local claim, fully proved by repo-side evidence. The
			// detector has no opinion and must say so.
			name: "repo-local claim with repo-side proof",
			item: CriterionItem{
				Met:       true,
				Criterion: "The deprecated helper is deleted and no caller remains in api/lib.",
				Evidence:  "PR #18004 merged, ancestor of origin/main; git grep finds no caller. mix test green.",
			},
			want: VerdictNotRuntime,
		},
		{
			// A runtime claim whose evidence IS a live observation. The row
			// claims the right kind of proof, so it leaves the suspect class.
			name: "runtime claim with a live probe",
			item: CriterionItem{
				Met:       true,
				Criterion: "GET /v1/tasks/events?doc_id= narrows the stream to one row.",
				Evidence:  "curl https://guerrilla.barkpark.cloud/v1/tasks/events?doc_id=x returned 200 and every event carried the target doc_id.",
			},
			want: VerdictLiveProbed,
		},
		{
			// An UNMET criterion asserts nothing yet. The class under audit is
			// SEALED claims; classifying an open one manufactures a finding
			// out of work still in progress.
			name: "unmet runtime claim is never classified",
			item: CriterionItem{
				Met:       false,
				Criterion: "GET /v1/tasks/events returns the actor on every event.",
				Evidence:  "",
			},
			want: VerdictNotRuntime,
		},
		{
			// Evidence in a style none of the three vocabularies recognises.
			// Calling it repo-side would be inventing a reading, so the row
			// stays out of the finding rather than being guessed into it.
			name: "unrecognised evidence style is not a finding",
			item: CriterionItem{
				Met:       true,
				Criterion: "The endpoint returns the new field.",
				Evidence:  "Reviewed with the owner on a call; agreed it is fine.",
			},
			want: VerdictNotRuntime,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ClassifyCriterion(tc.item); got != tc.want {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}

// TestMetWithoutEvidenceIsItsOwnVerdict keeps the two defects apart. A met with
// empty evidence is a write that did NOT land the way it was asked for — the
// server refuses that flip — and folding it into the unmeasured count would
// hide a different bug inside this one.
func TestMetWithoutEvidenceIsItsOwnVerdict(t *testing.T) {
	got := ClassifyCriterion(CriterionItem{
		Met:       true,
		Criterion: "GET /v1/tasks/events carries the actor.",
		Evidence:  "   ",
	})
	if got != VerdictNoEvidence {
		t.Fatalf("got %v, want %v", got, VerdictNoEvidence)
	}
}

// TestNonTerminalRowsAreExcluded asserts the SETUP, not just the verdict. A
// live row's criteria are still being worked; "nobody re-checked" is not a
// defect on a row nobody has finished. This arm reds if the terminal filter is
// dropped, and it reads the finding COUNT rather than its absence, so an
// empty result for the wrong reason cannot pass it.
func TestNonTerminalRowsAreExcluded(t *testing.T) {
	seal := CriterionItem{Met: true, Criterion: specimenCriterion, Evidence: specimenEvidence}

	open := TaskDetail{}
	open.DocID = "open-row"
	open.Lifecycle = "in_progress"
	open.CriteriaItems = []CriterionItem{seal}

	done := TaskDetail{}
	done.DocID = "done-row"
	done.Lifecycle = "done"
	done.CriteriaItems = []CriterionItem{seal}

	// Control: the same criterion on a TERMINAL row IS found, so the empty
	// result below is the filter firing and not the predicate failing.
	if got := RuntimeClaimFindings([]TaskDetail{done}); len(got) != 1 {
		t.Fatalf("control: the terminal row must produce exactly 1 finding, got %d", len(got))
	}
	if got := RuntimeClaimFindings([]TaskDetail{open}); len(got) != 0 {
		t.Fatalf("a non-terminal row must produce no finding, got %d", len(got))
	}
}

// TestEvidenceFallsBackToTheAlignedSlice pins the decode seam. Evidence reaches
// this package by two paths — on the CriterionItem and on the index-aligned
// TaskDetail.Evidence slice — and reading only the first made every row in a
// fixture look evidence-free, which would have reported real findings as the
// unrelated MET-WITHOUT-EVIDENCE defect.
func TestEvidenceFallsBackToTheAlignedSlice(t *testing.T) {
	d := TaskDetail{Evidence: []string{specimenEvidence}}
	d.DocID = "split-decode"
	d.Lifecycle = "done"
	d.CriteriaItems = []CriterionItem{{Met: true, Criterion: specimenCriterion}}

	got := RuntimeClaimFindings([]TaskDetail{d})
	if len(got) != 1 {
		t.Fatalf("want 1 finding, got %d", len(got))
	}
	if got[0].Verdict != VerdictUnmeasured {
		t.Fatalf("evidence on the aligned slice must classify like evidence on the item; got %v", got[0].Verdict)
	}
	if got[0].Ref() != "split-decode#0" {
		t.Fatalf("ref must cite doc and index; got %q", got[0].Ref())
	}
}

// TestFindingRefsAreStableAndIndexed guards the citation shape a human chases.
func TestFindingRefsAreStableAndIndexed(t *testing.T) {
	d := TaskDetail{}
	d.DocID = "multi"
	d.Lifecycle = "done"
	d.CriteriaItems = []CriterionItem{
		{Met: true, Criterion: "Docs updated.", Evidence: "PR #1 merged."},
		{Met: true, Criterion: specimenCriterion, Evidence: specimenEvidence},
	}
	got := RuntimeClaimFindings([]TaskDetail{d})
	if len(got) != 1 || got[0].Ref() != "multi#1" {
		t.Fatalf("the ref must carry the criterion's OWN index, not its position in the finding list; got %+v", got)
	}
}

// TestControlRefusesAFieldThatDoesNotDiscriminate is the control's own arm on
// this projection: when no row anywhere cites a live probe, the comparison is
// arithmetic on a constant and must refuse rather than report a ratio.
func TestControlRefusesAFieldThatDoesNotDiscriminate(t *testing.T) {
	var details []TaskDetail
	for _, id := range []string{"a", "b", "c", "d"} {
		d := TaskDetail{}
		d.DocID = id
		d.Lifecycle = "done"
		d.ClosedBy = "w1"
		d.CriteriaItems = []CriterionItem{
			{Met: true, Criterion: specimenCriterion, Evidence: specimenEvidence},
			{Met: true, Criterion: "Docs updated.", Evidence: "PR #1 merged."},
		}
		details = append(details, d)
	}
	rows := RuntimeClaimRows(details)
	if len(rows) != 8 {
		t.Fatalf("projection must emit one row per SEALED criterion; got %d want 8", len(rows))
	}
	v := ControlEnrichment(rows, ClassRuntimeClaim, ClassRepoLocalClaim, 2)
	if v.Discriminates {
		t.Fatalf("no row cites a probe, so the field discriminates nothing; verdict said it does: %s", v.Reason)
	}
	if v.Survives {
		t.Fatalf("a non-discriminating field can never survive; reason was %q", v.Reason)
	}
	if !strings.Contains(v.Reason, "does not discriminate") {
		t.Fatalf("the refusal must name WHICH killer fired; got %q", v.Reason)
	}
}

// TestControlSeparatesClassFromClosingWorker is the confound arm. Every absence
// here is authored by one worker who never cites a probe, across BOTH classes;
// the class itself carries no effect. A control that reported the marginal
// ratio would call this a finding.
func TestControlSeparatesClassFromClosingWorker(t *testing.T) {
	mk := func(id, closedBy string, runtimeProbed, repoProbed bool) TaskDetail {
		d := TaskDetail{}
		d.DocID = id
		d.Lifecycle = "done"
		d.ClosedBy = closedBy
		rt := CriterionItem{Met: true, Criterion: specimenCriterion, Evidence: specimenEvidence}
		if runtimeProbed {
			rt.Evidence = "curl https://example.invalid/v1/x returned 200; " + specimenEvidence
		}
		repo := CriterionItem{Met: true, Criterion: "Docs updated.", Evidence: "PR #1 merged."}
		if repoProbed {
			repo.Evidence = "curl https://example.invalid/health returned 200; PR #1 merged."
		}
		d.CriteriaItems = []CriterionItem{rt, repo}
		return d
	}
	// "sloppy" never probes anything; "careful" always does. Both classes move
	// together WITHIN each worker, so nothing survives pooling.
	var details []TaskDetail
	for _, id := range []string{"s1", "s2", "s3"} {
		details = append(details, mk(id, "sloppy", false, false))
	}
	for _, id := range []string{"c1", "c2", "c3"} {
		details = append(details, mk(id, "careful", true, true))
	}

	v := ControlEnrichment(RuntimeClaimRows(details), ClassRuntimeClaim, ClassRepoLocalClaim, 2)
	if !v.Discriminates {
		t.Fatalf("control setup is wrong: the field must discriminate here, else this arm measures nothing (%s)", v.Reason)
	}
	if v.Comparable < 2 {
		t.Fatalf("control setup is wrong: both workers must be comparable strata, got %d", v.Comparable)
	}
	if v.Survives {
		t.Fatalf("the absence tracks the closing worker, not the class; the control must NOT survive. reason=%q", v.Reason)
	}
}
