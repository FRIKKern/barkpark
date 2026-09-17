package cli

import (
	"strings"
	"testing"
)

// ─── THE POLARITY, RULED AND FENCED (task-573618865e3c2b3f) ─────────────────
//
// THE RULING, 2026-09-17, by main as orchestrator — the same authority as the
// 2026-09-13T12:19Z ruling that deferred it:
//
//	An explicit `merge_gate: true` STAYS FLIPPABLE by `bp task landed`. The
//	polarity is NOT inverted and task-4dca6c8453fb1f7c c2 is not implemented as
//	written. The fence c2 wanted exists in a better shape: the per-row
//	`merge_discharges: false` that PR #16619 shipped, ANDed with merge_shaped?/1.
//	A row whose lead wants `merge_gate: true` AND wants no landing notice to
//	seal it declares `merge_discharges: false` and gets exactly that, per row,
//	by its own author, with no other row affected.
//
// WHAT CHANGES BEHAVIOUR: nothing. The ruling is KEEP, so no row moves. What
// the INVERSION would have cost, re-measured 2026-09-17 with the shipped
// predicate over all 1451 rows carrying a `landed:pr-*` label (5298 criteria):
// 11 rows carry a resolvable candidate (exactly one each — the arity rule), and
// 7 of the 11 are candidates ONLY because of this polarity, i.e. these are the
// rows an inversion would have changed, BY ID rather than by count:
//
//	pds-bl-w48-web-gate-cannot-block-and-greens-vacuously  index 5
//	task-60242d26d69d805a                                  index 3
//	task-77f40fa9b56ba99f                                  index 3
//	task-7951b69c8a055b24                                  index 4
//	task-d2df3ffff3513c96                                  index 4
//	task-f0e49432f1653c2f                                  index 6
//	task-f79e39f4992749a5                                  index 4
//
// Under the KEEP ruling every one of them is unchanged: each stays resolvable
// and `bp task landed` keeps sending its index. The remaining 4 — task-4dca…
// index 2 and task-f56d553a70a4bba8 index 4 (prose marker), plus
// format-gate-red-on-main-teaches-dismissal index 3 and
// gr-backlog-d24-statusmeta-sweep index 2 (landing wording) — never depended on
// the field arm and are unaffected either way. Inverting would have cut the cure
// from 11 rows to those 4. The 2026-09-13 figure (two of nine) is SUPERSEDED and
// must not be re-quoted; re-cut the corpus and re-run
// TestMeasureLandedCandidatesOverCorpus with BP_LANDED_CORPUS_LIST=1 instead,
// which is why the harness and not the number is what this change ships.
//
// ─── WHY TWO TESTS AND NOT ONE ──────────────────────────────────────────────
//
// `merge_gate` IS NOT ONE THING, and a fence that covers one shape silently is
// a green with no subject. `landedMergeShaped` has two arms:
//
//	FIELD arm  — `c.mergeGate != nil` → the author's declaration, verbatim.
//	PROSE arm  — field ABSENT → the MERGE-GATE(D) marker in the stored text.
//
// A test that constructs a row with the FIELD set, asserts the outcome and
// stops will pass unchanged while the prose-keyed path is deleted: the
// assertion is fine and that code path never arrives. Both arms below are
// mutation-proved INDEPENDENTLY — each mutation reds its own test and leaves
// the other green — and disarming the predicate outright reds both. The
// mutations and their verified outcomes are recorded in the PR body.
//
// Measured 2026-09-17 over the whole live corpus (9062 rows, 38004 criteria):
// 2668 criteria are marker-worded, and on 1587 of them NO `merge_gate` key is
// present, so the prose arm alone decides. That is 1587 criteria a field-only
// fence would leave unfenced — which is why the second test exists.

// FIELD ARM. An explicit `merge_gate: true` is MERGE-SHAPED and therefore the
// candidate. This is the ruled polarity itself.
//
// MUTATION (verified): in `landedMergeShaped`, replace `return *c.mergeGate`
// with `return false`. This test reds on the missing `criterion=2`;
// TestTaskLanded_MergeGateWordingWithNoFieldIsTheCandidate stays GREEN, which
// is the whole point of splitting them.
func TestTaskLandedPolarity_FieldMergeGateTrueIsStillTheCandidate(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "The reconciler is proven by test, red-without and green-with"},
		{text: "docs/openapi.json enumerates the /ops error codes"},
		// Deliberately NOT marker-worded and NOT landing-worded: the FIELD is
		// the only thing that can admit this criterion, so the field arm is the
		// only arm under test. A text that also said "MERGE-GATED" would make
		// this test pass through the prose arm after the field mutation and
		// report a fence that is not there.
		{text: "The rollout note is filed and the owner is named", mergeGate: boolPtr(true)},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || !strings.Contains(posts[0], "criterion=2") {
		t.Fatalf("queries = %v — RULED 2026-09-17 by main: an explicit merge_gate:true STAYS "+
			"flippable by `bp task landed`, so index 2 is the candidate even though its text "+
			"carries no marker at all. If this reds because the polarity was deliberately "+
			"inverted, the ruling has been overturned: say so in the PR, re-cut the corpus and "+
			"re-run TestMeasureLandedCandidatesOverCorpus — the inversion cost 7 of 11 rows when "+
			"it was last measured, and the per-row remedy is `merge_discharges: false`, not an "+
			"inversion.", posts)
	}
}

// PROSE ARM. NO `merge_gate` key at all — the marker wording alone admits the
// criterion, which is how 1587 of the corpus's marker-bearing criteria are
// decided. The text is deliberately marker-worded WITHOUT being landing-worded
// ("merged to main" / "PR merged" would admit it through `landingWordedRe`
// instead and this test would then pin the wrong regex).
//
// MUTATION (verified): in `landedMergeShaped`, drop the
// `mergeGateWordedRe.MatchString(c.text) ||` term. This test reds on the
// missing `criterion=1`; TestTaskLandedPolarity_FieldMergeGateTrueIsStillTheCandidate
// stays GREEN.
//
// DISARM BOTH (verified): make `landedMergeShaped` `return false` outright and
// BOTH tests red, which is c4's "disarm the fence and both must red".
func TestTaskLanded_MergeGateWordingWithNoFieldIsTheCandidate(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "The reconciler is proven by test, red-without and green-with"},
		{text: "MERGE-GATED (the LEAD closes this criterion): the Elixir gate is green on the head sha and the squash sha is recorded here."},
	})

	_, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 || !strings.Contains(posts[0], "criterion=1") {
		t.Fatalf("queries = %v — index 1 carries NO merge_gate key, so the PROSE arm of "+
			"landedMergeShaped (mergeGateWordedRe, mirroring Barkpark.Tasks.Criteria's "+
			"@merge_gate_worded) is the only thing that can admit it. Measured 2026-09-17: "+
			"1587 of the live corpus's 2668 marker-worded criteria are decided this way, so a "+
			"fence that covers only the FIELD shape leaves that many criteria unfenced.", posts)
	}
}

// THE QUIET ARM — the exemption door, and the one thing the prose arm's
// deliberate WIDTH costs.
//
// The prose arm is wide on purpose (`Criteria.merge_gated?/1`'s moduledoc says
// so and has the measurement): a false positive is a loud refusal, a false
// negative is a silent fabricated done. The price is criteria that merely
// DISCUSS merge-gating and match anyway. Re-measured 2026-09-17: 66 of the 1587
// prose-arm-decided criteria merely mention it — 4.16%, against the moduledoc's
// 3.51% of 2026-08-22, so the rate has held while the denominator shrank.
//
// The documented remedy is `merge_gate: false`, NOT the `--merge-gated`
// override, and this test proves the door actually shuts: the SAME text, with
// and without the field, resolves differently. Take-up is the finding worth
// carrying: only 23 criteria in the corpus use the door against 66 that need
// it.
func TestTaskLanded_ProseMisfireIsShutByMergeGateFalse(t *testing.T) {
	// A real mis-fire shape, taken verbatim from the live corpus: a criterion
	// ABOUT merge-gating, which a merge cannot discharge.
	mention := "An audit reports how many existing tasks carry a merge-gate-worded criterion WITHOUT merge_gate:true. Evidence: the count and the query that produced it."

	t.Run("without the door the mis-fire IS resolved", func(t *testing.T) {
		cap := landedCriterionServer(t, []landedCrit{
			{text: "The reconciler is proven by test, red-without and green-with"},
			{text: mention},
		})
		if _, code := landWithNote(t); code != exitOK {
			t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
		}
		posts := cap.posts()
		if len(posts) != 1 || !strings.Contains(posts[0], "criterion=1") {
			t.Fatalf("queries = %v — this is the MIS-FIRE the wide prose arm is known to "+
				"produce. If it stopped firing, the prose arm was narrowed: re-measure before "+
				"calling that an improvement (the narrowing has been measured-refuted twice).", posts)
		}
	})

	t.Run("merge_gate:false shuts it, per row, by the author", func(t *testing.T) {
		cap := landedCriterionServer(t, []landedCrit{
			{text: "The reconciler is proven by test, red-without and green-with"},
			{text: mention, mergeGate: boolPtr(false)},
		})
		if _, code := landWithNote(t); code != exitOK {
			t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
		}
		posts := cap.posts()
		if len(posts) != 1 {
			t.Fatalf("landing POSTed %d times, want 1; queries = %v", len(posts), posts)
		}
		if strings.Contains(posts[0], "criterion=") {
			t.Fatalf("query = %q — an explicit merge_gate:false is the documented exemption "+
				"door for the prose arm's false positives. It must veto the wording outright, "+
				"and it is the remedy an author reaches for INSTEAD of `--merge-gated`.", posts[0])
		}
	})
}

// THE OTHER FENCE — the one the ruling points at instead of an inversion.
// `merge_discharges: false` on a row that ALSO carries `merge_gate: true` is
// what task-4dca6c8453fb1f7c c2 was actually asking for, scoped to one row: the
// lead still closes it, the builder is still refused, and no landing notice can
// seal it. Without this test the ruling's central claim — "the fence already
// exists in a better shape" — would be asserted and never checked.
func TestTaskLanded_MergeDischargesFalseIsThePerRowFence(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "The reconciler is proven by test, red-without and green-with"},
		{
			text:            "MERGE-GATED (the LEAD closes this): the PR is merged to main with the Elixir gate green.",
			mergeGate:       boolPtr(true),
			mergeDischarges: boolPtr(false),
		},
	})

	if _, code := landWithNote(t); code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 {
		t.Fatalf("landing POSTed %d times, want 1; queries = %v", len(posts), posts)
	}
	if strings.Contains(posts[0], "criterion=") {
		t.Fatalf("query = %q — index 1 is merge-SHAPED twice over (field AND wording) but its "+
			"author declared merge_discharges:false. That is the per-row fence the 2026-09-17 "+
			"ruling puts in place of inverting the polarity for every row; if it stops holding, "+
			"the ruling loses its alternative and the inversion question reopens.", posts[0])
	}
}
