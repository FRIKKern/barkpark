package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// liveAmbiguousDetails is the `details` payload the deployed server actually
// sends, captured verbatim from guerrilla on 2026-09-16 for the live twin
// `akbr-feedback-2026-08-epic`. A fixture invented from the doc would be a
// fixture that encodes a shape the system never emits.
const liveAmbiguousDetails = `{"datasets":["aker-brygge","production"],"doc_id":"akbr-feedback-2026-08-epic"}`

// carryingTaskGet is `task.get` AS DEPLOYED — it declares the `dataset` flag
// (PR #18611). taskRosterWithTwoCarriers above deliberately models the older,
// non-carrying shape, so this file needs its own.
func carryingTaskGet() manifest.Command {
	return manifest.Command{
		ID: "task.get", Noun: "task", Verb: "get",
		Args:  []manifest.Arg{{Name: "doc_id", Required: true}},
		Flags: []manifest.Flag{{Name: "dataset"}},
		HTTP:  manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/:doc_id"},
	}
}

// TestAmbiguousDatasetRemedyIsTypeable is the MEASURING ARM. Revert the change
// (delete the ae.datasetRemedy assignment in handleResponseHinted, or make
// ambiguousDatasetRemedy return "") and this reds: the operator is left with
// `?dataset=`, which has no place on a bp command line.
//
// It asserts BOTH dataset names. Asserting one would pass a build that picked a
// dataset for the caller — the behaviour the honest refusal replaced.
func TestAmbiguousDatasetRemedyIsTypeable(t *testing.T) {
	msg := ambiguousDatasetRemedy(carryingTaskGet(), nil, json.RawMessage(liveAmbiguousDetails))
	if msg == "" {
		t.Fatal("no remedy for a live ambiguous_dataset payload on a carrying command — this test measures nothing")
	}
	for _, want := range []string{"-d aker-brygge", "-d production", "`bp task get`"} {
		if !strings.Contains(msg, want) {
			t.Errorf("remedy does not carry %q, so the operator cannot type it.\nmessage: %s", want, msg)
		}
	}
	// It must not tell the caller to type the HTTP spelling.
	if strings.Contains(msg, "?dataset=") {
		t.Errorf("the remedy repeats the query-param spelling it exists to translate:\n%s", msg)
	}
}

// TestAmbiguousDatasetRemedyNeverNamesAnUntypeableFlag is the second direction
// of the same rule: on a command that CANNOT carry -d, printing `-d <name>`
// would hand back a remedy scope_honesty.go refuses on the next keystroke.
func TestAmbiguousDatasetRemedyNeverNamesAnUntypeableFlag(t *testing.T) {
	roster := taskRosterWithTwoCarriers()
	nonCarrier := roster[0] // task.get in the NON-declaring shape
	if manifest.DatasetFateFor(nonCarrier) == manifest.DatasetCarried {
		t.Fatal("fixture carries a dataset — this test would measure the wrong branch")
	}
	msg := ambiguousDatasetRemedy(nonCarrier, roster, json.RawMessage(liveAmbiguousDetails))
	if msg == "" {
		t.Fatal("no remedy at all on a non-carrying command — the operator gets nothing")
	}
	if strings.Contains(msg, "-d aker-brygge") || strings.Contains(msg, "-d production") {
		t.Errorf("a flag this command cannot carry is offered as the remedy:\n%s", msg)
	}
	for _, want := range []string{"`bp task ready`", "`bp task events`"} {
		if !strings.Contains(msg, want) {
			t.Errorf("remedy does not name the carrying sibling %s.\nmessage: %s", want, msg)
		}
	}
}

// TestAmbiguousDatasetRemedyIsQuietOffItsShape is the POSITIVE CONTROL. A
// remedy that fired on anything else would be noise on every unrelated refusal,
// and a line that always appears measures nothing.
func TestAmbiguousDatasetRemedyIsQuietOffItsShape(t *testing.T) {
	cases := []struct {
		name    string
		details string
	}{
		// The unambiguous id — the control the whole row turns on. No collision,
		// no details, no line.
		{"no details at all", ""},
		{"empty object", "{}"},
		{"null", "null"},
		// One dataset is not a collision: the id resolves and nothing is refused
		// for ambiguity, so advertising a disambiguator would be a lie.
		{"a single dataset", `{"datasets":["production"],"doc_id":"onix-quality-goal"}`},
		{"no datasets key", `{"similar":["task-abc"]}`},
		{"datasets is not a list of strings", `{"datasets":{"a":1}}`},
		{"blank names only", `{"datasets":["","  "]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ambiguousDatasetRemedy(carryingTaskGet(), nil, json.RawMessage(tc.details)); got != "" {
				t.Errorf("remedy fired on a payload that is not a cross-dataset collision: %q", got)
			}
		})
	}
}

// TestAmbiguousDatasetRemedyOnlyOnItsCode pins the dispatch gate rather than the
// deriver: every OTHER refusal must leave datasetRemedy empty even when its
// details happen to carry a `datasets` key.
func TestAmbiguousDatasetRemedyOnlyOnItsCode(t *testing.T) {
	if ambiguousDatasetCode != "ambiguous_dataset" {
		t.Fatalf("the gate keys on %q, which is not the server's code", ambiguousDatasetCode)
	}
	// The code is in the conflict bucket and this change must not move it.
	if got := exitForCode(ambiguousDatasetCode); got != exitConflict {
		t.Errorf("ambiguous_dataset exit moved to %d, want %d (exitConflict) — the exit ladder is the contract spine", got, exitConflict)
	}
}

// liveAmbiguousBody is the whole 409 envelope guerrilla returned on 2026-09-16
// for `bp task get akbr-feedback-2026-08-epic`, captured verbatim. The hint is
// the server's real sentence, and it is the one being translated.
const liveAmbiguousBody = `{"error":{"code":"ambiguous_dataset",` +
	`"details":{"datasets":["aker-brygge","production"],"doc_id":"akbr-feedback-2026-08-epic"},` +
	`"hint":"This task id exists in more than one dataset in this workspace/project, so the door ` +
	`refused rather than pick one for you. Name the dataset you mean (?dataset=<name> on ` +
	`the task route), or collapse the twin — details.datasets lists every dataset that holds the id.",` +
	`"message":"task akbr-feedback-2026-08-epic exists in more than one dataset in this ` +
	`workspace/project (aker-brygge, production); name one with ?dataset= — this door will not pick ` +
	`for you","request_id":"GNXl4J8s0_tX1sYAAIlB"},"ok":false}`

// TestAmbiguousDatasetRemedyReachesTheOperator is the DISPATCH arm. The deriver
// tests above call ambiguousDatasetRemedy directly, so they stay green if the
// assignment in handleResponseHinted is deleted — a green with no subject. This
// one drives the real dispatch and reads what the operator actually sees.
func TestAmbiguousDatasetRemedyReachesTheOperator(t *testing.T) {
	m := &manifest.Manifest{Commands: []manifest.Command{carryingTaskGet()}}

	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"

	rc := handleResponse(w, m, carryingTaskGet(), 409, []byte(liveAmbiguousBody))
	if rc != exitConflict {
		t.Fatalf("exit = %d, want %d (exitConflict) — the exit ladder must not move", rc, exitConflict)
	}
	got := se.String()

	// The server's hint stays the headline. This change is additive.
	if !strings.Contains(got, "Name the dataset you mean") {
		t.Errorf("the server's own hint was displaced:\n%s", got)
	}
	// And the translated remedy is there, typeable.
	for _, want := range []string{"-d aker-brygge", "-d production"} {
		if !strings.Contains(got, want) {
			t.Errorf("the operator never sees %q — the only printed remedy is the query-param "+
				"form, which has no place on a bp command line.\nstderr:\n%s", want, got)
		}
	}
}

// TestAmbiguousDatasetRemedyIsSilentOnOtherRefusals is the dispatch-side
// positive control: an unrelated 409 through the SAME call must gain no line.
func TestAmbiguousDatasetRemedyIsSilentOnOtherRefusals(t *testing.T) {
	m := &manifest.Manifest{Commands: []manifest.Command{carryingTaskGet()}}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"

	body := []byte(`{"error":{"code":"stale_claim","message":"the epoch moved",` +
		`"details":{"datasets":["aker-brygge","production"]}}}`)
	handleResponse(w, m, carryingTaskGet(), 409, body)
	if got := se.String(); strings.Contains(got, "-d aker-brygge") {
		t.Errorf("a stale_claim refusal grew a dataset remedy — the gate is not keyed on the code:\n%s", got)
	}
}

// TestUnambiguousIdIsUntouched is the control the row itself names: the unique
// slug. A 200 must render exactly as before.
func TestUnambiguousIdIsUntouched(t *testing.T) {
	m := &manifest.Manifest{Commands: []manifest.Command{carryingTaskGet()}}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if rc := handleResponse(w, m, carryingTaskGet(), 200, []byte(`{"doc":{"doc_id":"onix-quality-goal"}}`)); rc != exitOK {
		t.Fatalf("exit = %d on a successful read, want %d", rc, exitOK)
	}
	if se.Len() != 0 {
		t.Errorf("a successful read wrote to stderr:\n%s", se.String())
	}
}

// TestAmbiguousDatasetRemedyReachesTheDefaultOutput is the arm the stderr test
// could not be: `bp` renders the error ENVELOPE by default, so a remedy that
// lived only on the human stderr line would never reach the operator who typed
// the plain command. Measured live on 2026-09-16 — a bare `bp task get <twin>`
// wrote this envelope to stdout and zero bytes to stderr.
func TestAmbiguousDatasetRemedyReachesTheDefaultOutput(t *testing.T) {
	for _, mode := range []string{"json", "yaml"} {
		t.Run(mode, func(t *testing.T) {
			m := &manifest.Manifest{Commands: []manifest.Command{carryingTaskGet()}}
			var so, se bytes.Buffer
			w := newWriter(&so, &se)
			w.output = mode

			if rc := handleResponse(w, m, carryingTaskGet(), 409, []byte(liveAmbiguousBody)); rc != exitConflict {
				t.Fatalf("exit = %d, want %d", rc, exitConflict)
			}
			got := so.String()
			if !strings.Contains(got, "bp_remedy") {
				t.Fatalf("the machine envelope carries no bp_remedy — the default output is where the "+
					"operator reads the refusal.\nstdout:\n%s", got)
			}
			for _, want := range []string{"-d aker-brygge", "-d production"} {
				if !strings.Contains(got, want) {
					t.Errorf("envelope does not carry %q:\n%s", want, got)
				}
			}
			// The server's own words stay under their own key, unedited.
			if !strings.Contains(got, "Name the dataset you mean") {
				t.Errorf("the server hint was displaced from the envelope:\n%s", got)
			}
		})
	}
}

// TestErrorEnvelopeOmitsBpRemedyWhenEmpty is the byte-stability control: the
// ~60 call sites that pass no remedy must emit exactly what they emitted before.
func TestErrorEnvelopeOmitsBpRemedyWhenEmpty(t *testing.T) {
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "json"
	if !renderErrorEnvelopeDetailed(w, "not_found", "nope", "req-1", "look elsewhere", nil) {
		t.Fatal("envelope not rendered in json mode — this test measures nothing")
	}
	if strings.Contains(so.String(), "bp_remedy") {
		t.Errorf("an unrelated refusal grew a bp_remedy key:\n%s", so.String())
	}
}
