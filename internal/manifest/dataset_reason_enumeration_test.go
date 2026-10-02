package manifest

import (
	"fmt"
	"strings"
	"testing"
)

// TestNoDatasetReasonFreezesAVerbEnumeration is the guard that was missing when
// datasetDispositions["task"] went stale.
//
// THE INCIDENT. The Reason read "…and declare no dataset flag; task.events is
// the one ledger verb that declares its own `dataset` flag". True against the
// 2026-09-04 capture; FALSE against guerrilla on 2026-09-16, which declares a
// `dataset` flag on task.ready as well. An operator refused on `bp -d <ds> task
// get <id>` was handed a refusal naming ONE remedy out of two.
//
// WHY NO EXISTING TEST CAUGHT IT, and why this one is shaped the way it is. The
// obvious guard — "check the enumeration against the roster" — cannot work here:
// the only roster the suite owns is testdata/capabilities-guerrilla-2026-09-04.json,
// the very capture the sentence was written from, so the claim and its check go
// stale in lockstep and agree forever. An enumeration of a SERVER-SHIPPED roster
// is not checkable from a checked-in snapshot at all.
//
// So this guard does not check the enumeration. It forbids one: a Reason may
// state why THIS route cannot carry a dataset (a property of the route, which
// does not drift) and may not name a sibling command (a property of the roster,
// which does). The remedy is DERIVED at refusal time by DatasetCarryingSiblings.
//
// The predicate is mechanical, not a list: a Reason must not contain a
// command-id-shaped token of its own noun ("<noun>.<verb>"). Run against today's
// table it is silent; restore any of the five clauses that were removed and it
// reds naming the entry.
func TestNoDatasetReasonFreezesAVerbEnumeration(t *testing.T) {
	if len(datasetDispositions) == 0 {
		t.Fatal("datasetDispositions is empty — this guard measures nothing")
	}

	checked := 0
	for noun, d := range datasetDispositions {
		if d.Reason == "" {
			t.Errorf("datasetDispositions[%q] declares no Reason — the refusal has nothing to quote", noun)
			continue
		}
		checked++
		if idx := strings.Index(d.Reason, noun+"."); idx >= 0 {
			t.Errorf("datasetDispositions[%q].Reason names a sibling command (%q at offset %d).\n"+
				"A Reason states why THIS route cannot carry the flag; naming which siblings CAN is a claim\n"+
				"about the server-shipped roster, which drifts and which no checked-in fixture can hold.\n"+
				"Delete the clause — DatasetCarryingSiblings derives it from the live roster.\nReason: %s",
				noun, noun+".", idx, d.Reason)
		}
	}
	if checked == 0 {
		t.Fatal("no Reason was examined — the loop measured nothing")
	}
	t.Logf("%d dataset dispositions carry a drift-free Reason", checked)
}

// TestTheGuardRedsOnTheSentenceItWasWrittenFor is the CONTROL for the guard
// above: a guard that is silent on today's table proves nothing until it is
// shown to fire on the exact text that motivated it. This re-runs the same
// predicate against the RETIRED sentence and asserts a hit.
func TestTheGuardRedsOnTheSentenceItWasWrittenFor(t *testing.T) {
	const retired = "the task ledger routes address a task by doc_id with no dataset segment " +
		"and declare no dataset flag; task.events is the one ledger verb that declares its own `dataset` flag"

	if !strings.Contains(retired, "task.") {
		t.Fatal("the predicate does not fire on the sentence it was written for — it measures nothing")
	}

	// And the other direction: today's replacement must NOT trip it, or the
	// guard is merely banning the word "task".
	if got := datasetDispositions["task"].Reason; strings.Contains(got, "task.") {
		t.Fatalf("the shipped task Reason still trips the predicate: %s", got)
	}
}

// TestDatasetCarryingSiblingsIsDerivedNotRemembered drives the derivation on a
// roster built to be the shape the frozen prose got WRONG: a task family where
// TWO verbs declare a `dataset` flag and one does not.
func TestDatasetCarryingSiblingsIsDerivedNotRemembered(t *testing.T) {
	roster := []Command{
		{ID: "task.get", Noun: "task", Verb: "get",
			HTTP: HTTP{Method: "GET", PathTemplate: "/v1/tasks/:doc_id"}},
		{ID: "task.ready", Noun: "task", Verb: "ready", Flags: []Flag{{Name: "dataset"}},
			HTTP: HTTP{Method: "GET", PathTemplate: "/v1/tasks/ready"}},
		{ID: "task.events", Noun: "task", Verb: "events", Flags: []Flag{{Name: "dataset"}},
			HTTP: HTTP{Method: "GET", PathTemplate: "/v1/tasks/events"}},
		// A carrier in ANOTHER family must not leak in.
		{ID: "doc.get", Noun: "doc", Verb: "get",
			HTTP: HTTP{Method: "GET", PathTemplate: "/v1/data/doc/:dataset/:type/:id"}},
	}

	got := DatasetCarryingSiblings(roster, "task")
	want := []string{"task events", "task ready"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("DatasetCarryingSiblings(task) = %v, want %v (sorted, this noun only)", got, want)
	}

	// The non-carrying verb is excluded — otherwise the clause would name the
	// very door that just refused.
	for _, s := range got {
		if s == "task get" {
			t.Fatal("the refused verb itself is listed as a remedy")
		}
	}

	// A family with no carrier yields nothing rather than a misleading clause.
	if got := DatasetCarryingSiblings(roster, "session"); len(got) != 0 {
		t.Fatalf("DatasetCarryingSiblings(session) = %v, want empty for a family with no carrier", got)
	}

	// A nil roster is legal (no manifest to derive from) and stays quiet.
	if got := DatasetCarryingSiblings(nil, "task"); len(got) != 0 {
		t.Fatalf("DatasetCarryingSiblings(nil) = %v, want empty", got)
	}
}
