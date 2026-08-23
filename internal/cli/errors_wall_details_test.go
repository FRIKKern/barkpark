package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

// The two publish-wall codes carry details built PRECISELY so a rejection costs
// one retry: unknown_tag pairs each unknown name with its trgm-nearest
// registered tags (api tag_registry.ex: %{unknown: [name], suggestions:
// %{name => [nearest]}}), and duplicate_of carries the incumbent published id
// (api content/errors.ex: details.duplicate_of). The generic sorted key:value
// rendering prints those as two unrelated compact-JSON blobs — the per-name
// pairing and the one copyable id are exactly what it buries. These tests pin
// the actionable per-code human lines (charter D83b / ae-cli-error-details-render).

// unknownTagBody mirrors the server's real 422: unknown order follows the
// document's tag order, and one name has no suggestion at all.
const unknownTagBody = `{"error":{"code":"unknown_tag","message":"publish references unregistered tag(s): frontent, zzz","details":{"unknown":["frontent","zzz"],"suggestions":{"frontent":["frontend","content"],"zzz":[]}}}}`

const duplicateOfBody = `{"error":{"code":"duplicate_of","message":"document duplicates an already-published document","details":{"duplicate_of":"paper-incumbent-1","similar":[{"id":"paper-incumbent-1","score":0.97}]}}}`

func TestRenderErrorUnknownTagPerNameSuggestions(t *testing.T) {
	for _, shape := range []string{"table", "minimal"} {
		t.Run(shape, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = shape

			renderError(w, classifyError(422, []byte(unknownTagBody)))

			got := stderr.String()
			// One line per unknown name, carrying ITS suggestions.
			if !strings.Contains(got, `unknown tag "frontent" — did you mean: frontend, content`) {
				t.Fatalf("stderr missing the per-name suggestion line:\n%s", got)
			}
			// A name with no suggestions says so instead of vanishing.
			if !strings.Contains(got, `unknown tag "zzz" — no similar registered tag`) {
				t.Fatalf("stderr missing the no-suggestion line:\n%s", got)
			}
			// The per-name lines REPLACE the generic compact-JSON blobs.
			if strings.Contains(got, "suggestions: {") || strings.Contains(got, `unknown: [`) {
				t.Fatalf("generic detail lines leaked alongside the per-name rendering:\n%s", got)
			}
			// Server order (document tag order), not alphabetical: frontent first.
			if f, z := strings.Index(got, `"frontent"`), strings.Index(got, `"zzz"`); f == -1 || z == -1 || f > z {
				t.Fatalf("unknown names out of server order:\n%s", got)
			}
			if stdout.Len() != 0 {
				t.Fatalf("%s shape wrote to stdout:\n%s", shape, stdout.String())
			}
		})
	}
}

func TestRenderErrorUnknownTagSuggestionListIsBounded(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"

	body := `{"error":{"code":"unknown_tag","message":"x","details":{"unknown":["t"],"suggestions":{"t":["s1","s2","s3","s4","s5","s6","s7"]}}}}`
	renderError(w, classifyError(422, []byte(body)))

	got := stderr.String()
	if !strings.Contains(got, "did you mean: s1, s2, s3, s4, s5") {
		t.Fatalf("stderr missing the capped suggestion list:\n%s", got)
	}
	if strings.Contains(got, "s6") {
		t.Fatalf("suggestion list not bounded at %d:\n%s", maxTagSuggestions, got)
	}
}

func TestRenderErrorDuplicateOfLeadsWithIncumbentID(t *testing.T) {
	for _, shape := range []string{"table", "minimal"} {
		t.Run(shape, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = shape

			renderError(w, classifyError(409, []byte(duplicateOfBody)))

			got := stderr.String()
			if !strings.Contains(got, "duplicate of: paper-incumbent-1") {
				t.Fatalf("stderr missing the incumbent id line:\n%s", got)
			}
			// The remaining keys keep their generic rendering below the id line.
			if !strings.Contains(got, `similar: [{"id":"paper-incumbent-1","score":0.97}]`) {
				t.Fatalf("stderr lost the similar payload:\n%s", got)
			}
			if di, si := strings.Index(got, "duplicate of:"), strings.Index(got, "similar:"); di == -1 || si == -1 || di > si {
				t.Fatalf("incumbent id does not LEAD the detail lines:\n%s", got)
			}
			if stdout.Len() != 0 {
				t.Fatalf("%s shape wrote to stdout:\n%s", shape, stdout.String())
			}
		})
	}
}

// A wall code whose details are NOT the contracted shape falls back to the
// generic sorted key:value lines — never dropped, never a panic.
func TestRenderErrorWallCodeUncontractedShapeFallsBackGeneric(t *testing.T) {
	cases := []struct {
		name, body, wantLine string
	}{
		{
			"unknown_tag without unknown list",
			`{"error":{"code":"unknown_tag","message":"x","details":{"filter":"zzz"}}}`,
			"  filter: zzz",
		},
		{
			"duplicate_of without incumbent id",
			`{"error":{"code":"duplicate_of","message":"x","details":{"similar":["a"]}}}`,
			`  similar: ["a"]`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			w.output = "table"

			renderError(w, classifyError(422, []byte(tc.body)))

			if got := stderr.String(); !strings.Contains(got, tc.wantLine+"\n") {
				t.Fatalf("stderr missing generic fallback line %q:\n%s", tc.wantLine, got)
			}
		})
	}
}

// The machine channel is untouched by the per-code human rendering: -o json
// still carries the wall details VERBATIM, byte-order preserved.
func TestRenderErrorWallDetailsJSONVerbatim(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	renderError(w, classifyError(422, []byte(unknownTagBody)))

	var env struct {
		Error struct {
			Details json.RawMessage `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
		t.Fatalf("stdout is not parseable JSON (%v):\n%s", err, stdout.String())
	}
	want := `{"unknown":["frontent","zzz"],"suggestions":{"frontent":["frontend","content"],"zzz":[]}}`
	if got := string(env.Error.Details); got != want {
		t.Fatalf("details = %s, want %s", got, want)
	}
	if strings.Contains(stderr.String(), "unknown tag") {
		t.Fatalf("human lines leaked to stderr under -o json:\n%s", stderr.String())
	}
}

// Exit codes are a separate contract (pds-w33-bl-publish-wall-codes-exit-1 owns
// moving them); this feature must not touch them.
func TestWallDetailRenderingDoesNotChangeExitCodes(t *testing.T) {
	if ae := classifyError(422, []byte(unknownTagBody)); ae.exit != exitForCode("unknown_tag") {
		t.Fatalf("unknown_tag exit moved: %d", ae.exit)
	}
	if ae := classifyError(409, []byte(duplicateOfBody)); ae.exit != exitForCode("duplicate_of") {
		t.Fatalf("duplicate_of exit moved: %d", ae.exit)
	}
}
