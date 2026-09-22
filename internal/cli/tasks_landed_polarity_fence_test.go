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
//
// UPDATED 2026-09-20 (task-b40af0580ec7deb6). Those 1587 are exactly the
// population the IMPLICIT candidate door now declines to volunteer, and the
// prose-arm test below was INVERTED to pin the decline. The two-arm reading
// above still governs, with one seam moved: `landedMergeShaped` keeps BOTH arms
// verbatim (it is the stamp refusal's reader and must stay wide), while
// `landedImplicitCandidate` — a strictly later question — reads the FIELD arm
// only. So the arms are now fenced on two different surfaces: the field arm by
// the flip it still produces, the prose arm by the SKIP receipt it produces.

// FIELD ARM. An explicit `merge_gate: true` is MERGE-SHAPED and therefore the
// candidate. This is the ruled polarity itself.
//
// MUTATION (verified): in `landedMergeShaped`, replace `return *c.mergeGate`
// with `return false`. This test reds on the missing `criterion=2`;
// TestTaskLanded_MergeGateWordingWithNoFieldIsNotVolunteered stays GREEN, which
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

// ─── THE PROSE DOOR, SHUT (task-b40af0580ec7deb6, 2026-09-20) ───────────────
//
// THIS SECTION REPLACES A TEST THAT ASSERTED THE OPPOSITE.
// `TestTaskLanded_MergeGateWordingWithNoFieldIsTheCandidate` used to pin that a
// criterion carrying the MERGE-GATED marker and NO `merge_gate` key WAS the
// implicit candidate. That is the defect task-b40af0580ec7deb6 measured on a
// scratch row on 2026-09-20: `bp task landed` with no `--criterion` flipped
// such a criterion to met=true with the landing note as its evidence, while the
// lead's own close-time readers (`Close.merge_gate_synthetics/3`,
// `reconcile_locked/4`) are flag-only and would have refused the identical
// criterion. The two halves of the ledger disagreed about which criteria a
// merge seals, and the half that never asks won.
//
// WHAT IS NOT CHANGED, and it is the part worth reading twice: the WIDE
// predicate `landedMergeShaped` is untouched. It still mirrors
// `Tasks.Landed.merge_shaped?/1` and `Criteria.merge_gated?/1` exactly, wording
// arm and all, and the field-arm test above still passes unchanged — the
// 2026-09-17 KEEP ruling is not disturbed. What narrowed is one strictly later
// question, `landedImplicitCandidate`: whether the client VOLUNTEERS an index
// no human typed. Narrowing the wide reader itself is the FAILURE DIRECTION the
// row names, and the mis-fire test below still exercises the wording arm to
// prove the prose reader is still wide.
//
// THE COST LEDGER, both directions: a false negative here costs one typed
// `--criterion N`; the false positive it removes cost a met on a criterion
// nobody verified, on the population the backfill measured at ~65% unflagged.

// THE MUTATION TARGET. Restore the prose door — in `landedImplicitCandidate`,
// replace the body with `return landedMergeShaped(c)` (or with
// `c.mergeGate == nil || *c.mergeGate`, the other natural way to re-widen it) —
// and this test reds on the `criterion=1` that comes back.
// TestTaskLandedPolarity_FieldMergeGateTrueIsStillTheCandidate stays GREEN under
// that mutation, which is the whole reason the two live apart.
func TestTaskLanded_MergeGateWordingWithNoFieldIsNotVolunteered(t *testing.T) {
	cap := landedCriterionServer(t, []landedCrit{
		{text: "The reconciler is proven by test, red-without and green-with"},
		// Marker-worded and NOT landing-worded, and carrying no `merge_gate`
		// key at all: the PROSE arm is the only thing that could admit it, so
		// this fixture measures the prose door and nothing else.
		{text: "MERGE-GATED (the LEAD closes this criterion): the Elixir gate is green on the head sha and the squash sha is recorded here."},
	})

	out, code := landWithNote(t)
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d) — shutting the prose door must not fail the landing itself", code, exitOK)
	}
	posts := cap.posts()
	if len(posts) != 1 {
		t.Fatalf("landing POSTed %d times, want 1; queries = %v", len(posts), posts)
	}
	if strings.Contains(posts[0], "criterion=") {
		t.Fatalf("query = %q — index 1 carries the MERGE-GATED marker and NO merge_gate key. "+
			"A landing that names no criterion must not volunteer it: the close-time readers are "+
			"flag-only, so flipping it here records a met the lead's own close would have refused. "+
			"If this reds, the prose door was re-opened — see task-b40af0580ec7deb6.", posts[0])
	}
	// The omission must be SPOKEN. A silent skip reads as "nothing here was
	// merge-shaped", which is a different and false statement.
	if !strings.Contains(out, "did NOT volunteer") {
		t.Errorf("the run skipped a merge-gate-WORDED criterion and never said so; out:\n%s", out)
	}
	if !strings.Contains(out, "skipped #2 (index 1)") {
		t.Errorf("the receipt did not name WHICH criterion it declined to volunteer; out:\n%s", out)
	}
	if !strings.Contains(out, "--criterion N") {
		t.Errorf("the receipt named no way forward for an author who meant it; out:\n%s", out)
	}
}

// THE WIDE READER IS STILL WIDE — the control for the paragraph above. If
// `landedMergeShaped`'s wording arm were narrowed instead of the implicit door
// (the FAILURE DIRECTION the row names), the criterion below would fall out of
// the prose-only SKIP list entirely and the receipt would go quiet about it.
// Asserting the skip is therefore an assertion about the wide predicate, made
// through the one surface that reports it.
func TestTaskLanded_ProseArmStaysWideAndTheSkipProvesIt(t *testing.T) {
	cases := []struct {
		name string
		text string
	}{
		{"marker, hyphenated", "MERGE-GATED: a lead closes this after the squash."},
		{"marker, spaced", "This is the MERGE GATE for the row and the lead owns it."},
		{"landing wording", "PR merged and the sha recorded on the row."},
		{"merged to main", "The change is merged to main with the gates green."},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cap := landedCriterionServer(t, []landedCrit{{text: tc.text}})
			out, code := landWithNote(t)
			if code != exitOK {
				t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
			}
			if posts := cap.posts(); len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
				t.Fatalf("queries = %v — unflagged, so never volunteered", posts)
			}
			if !strings.Contains(out, "skipped #1 (index 0)") {
				t.Fatalf("the wide reader no longer reads %q as merge-gate-worded, so the receipt "+
					"said nothing about it. Narrowing landedMergeShaped is the FAILURE DIRECTION "+
					"task-b40af0580ec7deb6 names: it stays wide for the stamp refusal, and only "+
					"landedImplicitCandidate is narrow.\nout:\n%s", tc.text, out)
			}
		})
	}
}

// THE QUIET ARM — the prose arm's known mis-fires, and what the narrow implicit
// door did and did NOT change about them.
//
// The prose arm is wide on purpose (`Criteria.merge_gated?/1`'s moduledoc says
// so and has the measurement): a false positive is a loud refusal, a false
// negative is a silent fabricated done. The price is criteria that merely
// DISCUSS merge-gating and match anyway. Re-measured 2026-09-17: 66 of the 1587
// prose-arm-decided criteria merely mention it — 4.16%, against the moduledoc's
// 3.51% of 2026-08-22, so the rate has held while the denominator shrank.
//
// SINCE 2026-09-20 the mis-fire can no longer be RESOLVED INTO A FLIP by an
// unnamed landing — nothing unflagged can be — so its remaining cost is one
// line of receipt noise. `merge_gate: false` is still the documented door and
// still does strictly more: it takes the criterion out of the merge-shaped set
// entirely, so it is not even mentioned. That difference is what this test
// measures, and it is also a live assertion that the wide reader still reads the
// text at all.
func TestTaskLanded_ProseMisfireIsShutByMergeGateFalse(t *testing.T) {
	// A real mis-fire shape, taken verbatim from the live corpus: a criterion
	// ABOUT merge-gating, which a merge cannot discharge.
	mention := "An audit reports how many existing tasks carry a merge-gate-worded criterion WITHOUT merge_gate:true. Evidence: the count and the query that produced it."

	t.Run("with no flag the mis-fire is skipped, loudly", func(t *testing.T) {
		cap := landedCriterionServer(t, []landedCrit{
			{text: "The reconciler is proven by test, red-without and green-with"},
			{text: mention},
		})
		out, code := landWithNote(t)
		if code != exitOK {
			t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
		}
		posts := cap.posts()
		if len(posts) != 1 || strings.Contains(posts[0], "criterion=") {
			t.Fatalf("queries = %v — before task-b40af0580ec7deb6 this mis-fire WAS resolved into "+
				"a flip on its wording alone. It must not be: it carries no merge_gate key.", posts)
		}
		if !strings.Contains(out, "skipped #2 (index 1)") {
			t.Fatalf("the mis-fire was skipped SILENTLY, or the wide reader stopped matching it "+
				"at all (the FAILURE DIRECTION); out:\n%s", out)
		}
	})

	t.Run("merge_gate:false shuts it entirely, per row, by the author", func(t *testing.T) {
		cap := landedCriterionServer(t, []landedCrit{
			{text: "The reconciler is proven by test, red-without and green-with"},
			{text: mention, mergeGate: boolPtr(false)},
		})
		out, code := landWithNote(t)
		if code != exitOK {
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
		// Strictly more than the narrow door: an explicit false leaves the
		// merge-shaped set, so it is not even reported as a skip. This is the
		// one assertion that separates "unflagged" from "declared not-a-gate".
		if strings.Contains(out, "skipped #2 (index 1)") {
			t.Fatalf("merge_gate:false was reported as a merge-gate-worded SKIP — an explicit "+
				"false is not a missing flag, it is a declaration that the criterion is not a "+
				"gate at all, and it must leave the merge-shaped set outright.\nout:\n%s", out)
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
