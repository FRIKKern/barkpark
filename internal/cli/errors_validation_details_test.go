package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// THE ROW: pds-bl-task-criteria-publish-label-spine-opacity.
//
// Two refusals were measured on 2026-07-31 as opaque one-liners with NO field:
// `document failed the publish wall's label spine` and `task content failed
// validation`. The cause was ONE defect — the CLI dropped the server's
// `details` payload — closed by #8809 (machine envelope) and #13314/#13641
// (human lines) on 2026-08-01 and after. The tests below are the RATCHET for
// those two shapes: they are the two BODIES the server actually emits, quoted
// from the live wire, so a future decoder that stops threading details through
// reds here rather than shipping another unactionable refusal.
//
// They also pin the remaining half of the honesty gap, which was still live on
// main when this row was worked: a `validation_failed` payload is
// `{field: [reason, …]}` and the generic detail renderer printed it as compact
// JSON, so the reader got
//
//	lifecycle_status: ["must be one of [\"open\", …], got \"\\\"bogus\\\"\""]
//
// — the reason wrapped in brackets and escaped twice. The rule is in there; a
// human cannot read it. validationFailedLines renders one `field: reason` line
// instead.

// liveLabelSpineBody is the VERBATIM 422 body behind `bp doc publish task
// task-761264e7e51373dd`, driven against guerrilla on 2026-09-10 with a tag
// rationale one character under the 20-char floor.
const liveLabelSpineBody = `{"error":{"code":"label_spine","message":"document failed the publish wall's label spine","hint":"Give the document a non-trivial description and 1-12 weighted tags","details":{"field":"rationale","fix":"Explain in entry #0 why this tag earns its strength (≥20 chars).","index":0,"rule":"A rationale must be at least 20 characters — it calibrates the strength."}}}`

// liveTaskContentBody is the VERBATIM 422 body behind `bp doc patch task … --set
// 'priority:=9'`, same session. This is the refusal the row measured as having
// "NO details at all".
const liveTaskContentBody = `{"error":{"code":"validation_failed","message":"task content failed validation","hint":"Fix the listed validation errors to match the schema, then resubmit.","details":{"priority":["must be an integer 0..4 when set, got 9"]}}}`

// The label-spine refusal must name the field, the rule and the fix on the
// HUMAN shapes. Ratchet for the first measured failure.
func TestLabelSpineRefusalNamesFieldRuleAndFix(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	renderError(w, classifyError(422, []byte(liveLabelSpineBody)))

	got := stderr.String()
	for _, want := range []string{
		"  field: rationale",
		"  index: 0",
		"  rule: A rationale must be at least 20 characters",
		"  fix: Explain in entry #0 why this tag earns its strength",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("the label-spine refusal is opaque again — missing %q:\n%s", want, got)
		}
	}
}

// The task-content refusal must name the field and the rule, and the rule must
// be READABLE: no JSON array brackets, no doubled escapes. This is the detector
// for validationFailedLines — without it the line is
// `priority: ["must be an integer 0..4 when set, got 9"]`.
func TestTaskContentRefusalNamesFieldAndReadableRule(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	renderError(w, classifyError(422, []byte(liveTaskContentBody)))

	got := stderr.String()
	want := "  priority: must be an integer 0..4 when set, got 9\n"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr missing the readable validation line %q:\n%s", want, got)
	}
	if strings.Contains(got, `["must be`) {
		t.Fatalf("the reason is still wrapped in JSON array brackets:\n%s", got)
	}
}

// A reason carrying its own quotes must reach the reader with ONE level of
// escaping, not the doubled `\\\"` the compact-JSON rendering produced.
func TestValidationFailedReasonKeepsSingleEscaping(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	body := `{"error":{"code":"validation_failed","message":"task content failed validation","details":{"lifecycle_status":["must be one of [\"open\", \"done\"], got \"bogus\""]}}}`
	renderError(w, classifyError(422, []byte(body)))

	got := stderr.String()
	want := `  lifecycle_status: must be one of ["open", "done"], got "bogus"` + "\n"
	if !strings.Contains(got, want) {
		t.Fatalf("stderr missing the singly-escaped line %q:\n%s", want, got)
	}
	if strings.Contains(got, `\"`) {
		t.Fatalf("the reason is still double-escaped:\n%s", got)
	}
}

// Several reasons on one field join on "; " — the algorithm apierr.DetailParts
// already applies for the one-line surfaces, so the two presentations agree.
func TestValidationFailedJoinsMultipleReasons(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	body := `{"error":{"code":"validation_failed","message":"bad","details":{"title":["can't be blank","is too short"],"priority":["must be an integer 0..4"]}}}`
	renderError(w, classifyError(422, []byte(body)))

	got := stderr.String()
	for _, want := range []string{
		"  priority: must be an integer 0..4\n",
		"  title: can't be blank; is too short\n",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stderr missing %q:\n%s", want, got)
		}
	}
	// Sorted by key, exactly like the generic renderer.
	if strings.Index(got, "  priority:") > strings.Index(got, "  title:") {
		t.Fatalf("validation detail lines are not sorted by key:\n%s", got)
	}
}

// A validation_failed payload whose values are NOT string lists (the
// `invalid_schema_fields` shape is `{reason: "…"}`, `invalid_dataset` mixes)
// keeps the generic rendering rather than losing bytes.
func TestValidationFailedNonListValuesFallBack(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	body := `{"error":{"code":"validation_failed","message":"bad","details":{"reason":"unknown field type","limit":12,"nested":{"a":1}}}}`
	renderError(w, classifyError(422, []byte(body)))

	got := stderr.String()
	for _, want := range []string{
		"  limit: 12\n",
		`  nested: {"a":1}` + "\n",
		"  reason: unknown field type\n",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("stderr missing %q:\n%s", want, got)
		}
	}
}

// Non-object details under validation_failed fall back to the single
// `details: …` line — the per-code renderer must never swallow a shape it does
// not recognise.
func TestValidationFailedNonObjectDetailsFallBack(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	renderError(w, classifyError(422, []byte(`{"error":{"code":"validation_failed","message":"bad","details":["a","b"]}}`)))

	if got := stderr.String(); !strings.Contains(got, `  details: ["a","b"]`) {
		t.Fatalf("stderr missing the non-object fallback line:\n%s", got)
	}
}

// The machine channel is untouched: -o json still carries `details` VERBATIM,
// with the array shape intact, because a script parses it.
func TestValidationFailedMachineChannelKeepsRawDetails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	renderError(w, classifyError(422, []byte(liveTaskContentBody)))

	got := stdout.String()
	if !strings.Contains(got, `"priority":["must be an integer 0..4 when set, got 9"]`) {
		t.Fatalf("the machine envelope lost the raw details array:\n%s", got)
	}
	if stderr.Len() != 0 {
		t.Fatalf("json shape wrote to stderr:\n%s", stderr.String())
	}
}

// `null` and `[]` decode into an empty []string with NO error, so an unguarded
// join would print a bare `field: ` line — an unreadable line traded for an
// empty one. Both must print verbatim.
func TestValidationFailedEmptyAndNullReasonLists(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	body := `{"error":{"code":"validation_failed","message":"bad","details":{"empty":[],"missing":null}}}`
	renderError(w, classifyError(422, []byte(body)))

	got := stderr.String()
	if !strings.Contains(got, "  empty: []\n") {
		t.Fatalf("an empty reason list must print verbatim, not as a bare field line:\n%s", got)
	}
	// Parity with the generic renderer is the contract for every shape this
	// per-code arm does not improve: a null value prints exactly as detailLines
	// prints it (empty), and that pre-existing rendering must not silently
	// change under a code-specific branch.
	generic := detailLines(json.RawMessage(`{"empty":[],"missing":null}`))
	for _, want := range generic {
		if !strings.Contains(got, "  "+want+"\n") {
			t.Fatalf("validation_failed drifted from the generic rendering — missing %q:\n%s", want, got)
		}
	}
}
