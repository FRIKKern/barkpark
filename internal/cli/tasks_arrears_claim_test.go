package cli

import (
	"strings"
	"testing"
	"time"
)

// productionArrearsEnvelope is the REAL wire shape, captured 2026-09-17 from
// `bp task get task-b189f81094ce474a -o json` immediately after `bp task
// release` on production (scratch row for
// cchi-w46-bl-lapsed-claim-arrears-close-path). Nothing here is invented: the
// absence of `lease_expires_at`, the preserved-and-bumped epoch, and the
// present-but-null `worker` are all facts of that response, and each one is a
// key a naive reader would have keyed on and been wrong.
const productionArrearsEnvelope = `{"doc":{
  "doc_id":"task-b189f81094ce474a",
  "lifecycle_status":"open",
  "claim":{"epoch":2,"released_at":"2026-09-17T12:54:35.233466Z","released_by":"cli-r21-w31-scratch",
           "ts_iso":"2026-09-17T12:54:34.986638Z","worker":null},
  "content":{"acceptance_criteria":[
     {"criterion":"If PR #0 merges and the gate is green on its head, this criterion flips.","evidence":"","merge_gate":true,"met":false}]}}}`

// TestArrearsClaimFiresOnTheMeasuredProductionShape is the arm that REDS on
// reversion. It runs the captured envelope through the detector and asserts
// every load-bearing clause of the notice.
func TestArrearsClaimFiresOnTheMeasuredProductionShape(t *testing.T) {
	a, ok := arrearsClaimFrom([]byte(productionArrearsEnvelope))
	if !ok {
		t.Fatalf("the measured production arrears shape was NOT detected; the notice is dead for the whole population this row is about")
	}
	if a.DocID != "task-b189f81094ce474a" {
		t.Fatalf("doc_id = %q, want the slug from the envelope", a.DocID)
	}
	if a.Epoch != 2 {
		t.Fatalf("epoch = %d, want 2 — release PRESERVES and BUMPS the epoch; a detector reading 0 here is keying on the wrong field", a.Epoch)
	}
	if a.Unmet != 1 || a.Total != 1 {
		t.Fatalf("unmet/total = %d/%d, want 1/1", a.Unmet, a.Total)
	}
	if !a.MergeGate {
		t.Fatalf("MergeGate = false; the captured criterion carries \"merge_gate\": true")
	}

	got := strings.Join(arrearsClaimLines(a), "\n")
	for _, want := range []string{
		"CRITERIA IN ARREARS",
		"task-b189f81094ce474a",
		"claim.worker is null",
		"claim.epoch=2",
		"1 of 1 criteria still unmet",
		"cli-r21-w31-scratch",
		// The close path, measured: re-claim is direct.
		"bp task claim task-b189f81094ce474a <worker> --yes",
		"DIRECTLY re-claimable",
		"no release step is needed",
		// The handle, which is how sweeps lose these rows.
		"`bp task get <uuid>` answers not_found",
		// Both server refusals, named as CORRECT.
		"criteria_unmet:N",
		"merge_gated_criterion",
		"--criterion-text-file",
		"--merge-gated",
		// The four-part per-row check; no batch close.
		"ancestor of origin/main",
		"a batch close fabricates a done",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("notice is missing %q\n--- notice ---\n%s", want, got)
		}
	}
}

// TestArrearsClaimSilentCases is the arm that must stay QUIET. Each case is a
// shape a looser detector would have fired on, and each one would be a false
// accusation on a row that is fine.
func TestArrearsClaimSilentCases(t *testing.T) {
	cases := map[string]string{
		// Somebody's LIVE work. Not arrears; tasks_stranded_claim.go owns the
		// held shapes.
		"in_progress row with a live holder": `{"doc":{"doc_id":"t1","lifecycle_status":"in_progress",
			"claim":{"epoch":1,"worker":"w1","lease_expires_at":"2999-01-01T00:00:00Z"},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// The STRANDED shape — open, but still wearing a holder's name. Firing
		// here would double-report the same row with two contradictory notices.
		"stranded: open but claim.worker non-blank": `{"doc":{"doc_id":"t2","lifecycle_status":"open",
			"claim":{"epoch":1,"worker":"w1","lease_expires_at":"2999-01-01T00:00:00Z"},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// Never claimed: no claim object at all. No arrears to pay.
		"never-claimed row": `{"doc":{"doc_id":"t3","lifecycle_status":"open",
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// A claim object with epoch 0 is not a claim that ever ran.
		"claim object with epoch 0": `{"doc":{"doc_id":"t4","lifecycle_status":"open",
			"claim":{"epoch":0,"worker":null},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// Closed rows keep claim.worker beside closed_by; and a closed row is
		// not in arrears whatever its criteria say.
		"closed row": `{"doc":{"doc_id":"t5","lifecycle_status":"open",
			"claim":{"epoch":2,"worker":null,"closed_at":"2026-09-01T00:00:00Z","closed_by":"w1"},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// A lapsed claim over a FULLY STAMPED row is just an idle row. The
		// arrears IS the unmet criterion, not the lapsed claim.
		"lapsed claim, every criterion met": `{"doc":{"doc_id":"t6","lifecycle_status":"open",
			"claim":{"epoch":2,"worker":null,"released_by":"w1"},
			"content":{"acceptance_criteria":[{"criterion":"c","met":true}]}}}`,

		// A row with no criteria at all (goals, decisions) owes nothing.
		"no acceptance criteria": `{"doc":{"doc_id":"t7","lifecycle_status":"open",
			"claim":{"epoch":2,"worker":null,"released_by":"w1"},"content":{}}}`,

		// Off the board entirely.
		"done row": `{"doc":{"doc_id":"t8","lifecycle_status":"done",
			"claim":{"epoch":2,"worker":null},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,

		// Not a task envelope.
		"unrelated envelope": `{"ok":true,"result":{"schemas":[]}}`,
	}
	for name, body := range cases {
		if a, ok := arrearsClaimFrom([]byte(body)); ok {
			t.Errorf("%s: the arrears notice FIRED on a row that is not in arrears: %+v", name, a)
		}
	}
}

// TestArrearsAndStrandedAreMutuallyExclusive proves the two notices partition
// the claim lifecycle rather than overlapping: the discriminator is
// claim.worker's VALUE, so no single envelope can satisfy both.
func TestArrearsAndStrandedAreMutuallyExclusive(t *testing.T) {
	now := time.Now().UTC()
	bodies := []string{
		productionArrearsEnvelope,
		// The stranded shape, from tasks_stranded_claim.go's own measurement.
		`{"doc":{"doc_id":"t9","lifecycle_status":"open",
			"claim":{"epoch":1,"worker":"w1","lease_expires_at":"2999-01-01T00:00:00Z"},
			"content":{"acceptance_criteria":[{"criterion":"c","met":false}]}}}`,
	}
	for _, body := range bodies {
		_, arrears := arrearsClaimFrom([]byte(body))
		_, stranded := strandedClaimFrom([]byte(body), now)
		if arrears && stranded {
			t.Errorf("both notices fired on one envelope — they must partition the lifecycle:\n%s", body)
		}
		if !arrears && !stranded {
			t.Errorf("neither notice fired on a shape that is one of the two:\n%s", body)
		}
	}
}

// TestArrearsMergeGateLineIsFlagKeyed pins the gate line to the STRUCTURAL
// merge_gate flag on an UNMET criterion. The server's own guard falls back to
// matching the prose, at a measured 3.5% false-positive rate over the live
// corpus; this notice must not inherit that, and must not name a gate that is
// already paid.
func TestArrearsMergeGateLineIsFlagKeyed(t *testing.T) {
	// Prose only, no flag: the reader is NOT told a gate blocks them.
	prose := `{"doc":{"doc_id":"tA","lifecycle_status":"open",
		"claim":{"epoch":2,"worker":null},
		"content":{"acceptance_criteria":[{"criterion":"the MERGE GATE is mentioned here as prose","met":false}]}}}`
	a, ok := arrearsClaimFrom([]byte(prose))
	if !ok {
		t.Fatalf("prose row should still be arrears")
	}
	if a.MergeGate {
		t.Errorf("MergeGate keyed on PROSE — that inherits the server guard's measured prose false-positive rate")
	}
	if strings.Contains(strings.Join(arrearsClaimLines(a), "\n"), "MERGE GATE:") {
		t.Errorf("gate line emitted for a prose-only criterion")
	}

	// Flag set, but on a criterion already MET: the gate is paid, so the line
	// must not fire off a different criterion's arrears.
	paid := `{"doc":{"doc_id":"tB","lifecycle_status":"open",
		"claim":{"epoch":2,"worker":null},
		"content":{"acceptance_criteria":[
			{"criterion":"gate","met":true,"merge_gate":true},
			{"criterion":"ordinary","met":false}]}}}`
	b, ok := arrearsClaimFrom([]byte(paid))
	if !ok {
		t.Fatalf("row with one unmet ordinary criterion should be arrears")
	}
	if b.MergeGate {
		t.Errorf("gate line fired off an ALREADY-MET merge-gated criterion")
	}
	if b.Unmet != 1 || b.Total != 2 {
		t.Errorf("unmet/total = %d/%d, want 1/2", b.Unmet, b.Total)
	}
}

// TestArrearsClaimReadsInsideAResultWrapper pins the two-shape envelope walk the
// sibling detectors keep: a body nested under {"result": …} must be seen.
func TestArrearsClaimReadsInsideAResultWrapper(t *testing.T) {
	wrapped := `{"ok":true,"result":` + productionArrearsEnvelope + `}`
	if _, ok := arrearsClaimFrom([]byte(wrapped)); !ok {
		t.Fatalf("arrears shape inside a {\"result\": …} wrapper was missed")
	}
}
