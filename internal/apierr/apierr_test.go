package apierr

import (
	"strings"
	"testing"
)

// THE REGRESSION THAT CREATED THIS PACKAGE. A typed `details` made one
// unexpected shape discard the entire envelope. Parse must return code,
// message and hint intact no matter what `details` turns out to be — that
// property is the reason the package exists, so it is pinned first and over
// every shape the field has plausibly taken.
func TestAnyDetailsShapeKeepsTheEnvelope(t *testing.T) {
	shapes := []struct {
		name    string
		details string
	}{
		{"dedup candidate lists", `{"similar":[{"id":"task-a","similarity":0.9}],"advise":[]}`},
		{"validation field map", `{"title":["is required"]}`},
		{"flat string map", `{"duplicate_of":"post-1"}`},
		{"label spine object", `{"field":"labels","rule":"weighted","fix":"…","index":2}`},
		{"bare list", `["a","b"]`},
		{"list of numbers", `[1,2,3]`},
		{"scalar string", `"nope"`},
		{"number", `7`},
		{"bool", `true`},
		{"null", `null`},
		{"deeply nested", `{"a":{"b":{"c":[{"d":1}]}}}`},
		{"empty object", `{}`},
	}
	for _, s := range shapes {
		t.Run(s.name, func(t *testing.T) {
			body := `{"error":{"code":"some_code","message":"the real message",` +
				`"hint":"the remedy sentence","request_id":"req-1","details":` + s.details + `}}`
			env, ok := Parse([]byte(body))
			if !ok {
				t.Fatalf("details %s made Parse reject the whole envelope", s.details)
			}
			if env.Code != "some_code" {
				t.Errorf("details %s cost the code: %q", s.details, env.Code)
			}
			if env.Message != "the real message" {
				t.Errorf("details %s cost the message: %q", s.details, env.Message)
			}
			if env.HintLine() != "the remedy sentence" {
				t.Errorf("details %s cost the HINT — the sentence that says what to do: %q", s.details, env.HintLine())
			}
			if env.RequestID != "req-1" {
				t.Errorf("details %s cost the request id: %q", s.details, env.RequestID)
			}
		})
	}
}

// Parse's admission test: an error OBJECT with a code or a message. Everything
// else is somebody else's shape and must be declined cleanly, not guessed at.
func TestParseAdmission(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"code only", `{"error":{"code":"x"}}`, true},
		{"message only", `{"error":{"message":"m"}}`, true},
		{"code and message", `{"error":{"code":"x","message":"m"}}`, true},
		{"empty error object", `{"error":{}}`, false},
		{"bare string error", `{"error":"halted"}`, false},
		{"null error", `{"error":null}`, false},
		{"no error key", `{"ok":true}`, false},
		{"ok-false reason shape", `{"ok":false,"reason":"invalid_edge"}`, false},
		{"not json", `<html>502</html>`, false},
		{"empty body", ``, false},
		{"bare array", `[]`, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if _, ok := Parse([]byte(c.body)); ok != c.want {
				t.Errorf("Parse(%s) ok = %v, want %v", c.body, ok, c.want)
			}
		})
	}
}

// Summary keeps the one-line shape the surfaces that adopt it already printed:
// message, falling back to code, with field→reasons appended sorted. Adopting
// this package must not change what a one-line surface renders.
func TestSummaryMatchesTheOneLineShape(t *testing.T) {
	env, ok := Parse([]byte(`{"error":{"code":"validation_failed","message":"validation failed",` +
		`"details":{"title":["is required"],"kind":["is required","must be a string"]}}}`))
	if !ok {
		t.Fatal("Parse declined a canonical envelope")
	}
	want := "validation failed — kind: is required; must be a string · title: is required"
	if got := env.Summary(); got != want {
		t.Errorf("Summary()\n got: %q\nwant: %q", got, want)
	}

	// Code fallback when the server sent no message.
	codeOnly, _ := Parse([]byte(`{"error":{"code":"not_found"}}`))
	if got := codeOnly.Summary(); got != "not_found" {
		t.Errorf("Summary() with no message = %q, want the code", got)
	}

	// Summary must NOT swallow the hint — a one-line caller has spent its line,
	// and a caller with room asks for HintLine explicitly.
	hinted, _ := Parse([]byte(`{"error":{"code":"c","message":"m","hint":"do the thing"}}`))
	if strings.Contains(hinted.Summary(), "do the thing") {
		t.Errorf("Summary() inlined the hint, which changes every one-line surface: %q", hinted.Summary())
	}
	if hinted.HintLine() != "do the thing" {
		t.Errorf("HintLine() = %q", hinted.HintLine())
	}
}

// The dedup candidates — the ids a duplicate_task refusal instructs the caller
// to pass while the old decoder withheld them.
func TestCandidatesCarryTheIDs(t *testing.T) {
	env, ok := Parse([]byte(`{"error":{"code":"duplicate_task","message":"dupe","details":{` +
		`"similar":[{"id":"task-abc","similarity":0.91,"relation":"same_surface","lifecycle_status":"open"}],` +
		`"advise":[{"id":"task-def","similarity":0.4}]}}}`))
	if !ok {
		t.Fatal("Parse declined the dedup envelope")
	}
	similar, advise := env.Candidates()
	if len(similar) != 1 || similar[0].ID != "task-abc" {
		t.Fatalf("similar = %+v", similar)
	}
	if len(advise) != 1 || advise[0].ID != "task-def" {
		t.Fatalf("advise = %+v", advise)
	}
	line := similar[0].Line("matches")
	for _, want := range []string{"matches task-abc", "similarity 0.91", "same_surface", "open"} {
		if !strings.Contains(line, want) {
			t.Errorf("Line() = %q, missing %q", line, want)
		}
	}
	// Id-less rows render nothing: naming the id is the entire point.
	if got := (Candidate{Similarity: 0.9}).Line("matches"); got != "" {
		t.Errorf("an id-less candidate rendered %q, want \"\"", got)
	}
	// A non-candidate details shape yields no candidates rather than an error.
	other, _ := Parse([]byte(`{"error":{"code":"c","message":"m","details":{"title":["required"]}}}`))
	if s, a := other.Candidates(); s != nil || a != nil {
		t.Errorf("field-map details produced candidates: %+v %+v", s, a)
	}
}

// The two details renderings are DIFFERENT VIEWS of the same payload, and the
// caller picks. DetailParts is deliberately generic — it renders every key,
// falling back to compact JSON, so nothing is ever silently dropped (that
// generality is why it was adopted as canonical). Candidates is the structured
// view of the dedup shape specifically. A caller that renders candidates as
// id-leading lines simply does not also print the raw blob; that is a
// presentation choice, not a property of the parser.
func TestBothDetailViewsAreAvailableAndTheCallerPicks(t *testing.T) {
	dedup, _ := Parse([]byte(`{"error":{"code":"duplicate_task","message":"d","details":{"similar":[{"id":"t-1"}]}}}`))
	// The generic view renders it rather than dropping it.
	if parts := dedup.DetailParts(); len(parts) != 1 || !strings.HasPrefix(parts[0], "similar: ") {
		t.Errorf("generic view dropped or mangled candidate details: %q", parts)
	}
	// The structured view extracts the ids.
	sim, _ := dedup.Candidates()
	if len(sim) != 1 || sim[0].ID != "t-1" {
		t.Errorf("structured view missed the candidate: %+v", sim)
	}

	// A field-map payload has no candidate view — nil, not an error.
	fields, _ := Parse([]byte(`{"error":{"code":"validation_failed","message":"v","details":{"title":["req"]}}}`))
	if s, a := fields.Candidates(); len(s) != 0 || len(a) != 0 {
		t.Errorf("field details produced candidates: %+v %+v", s, a)
	}
	if parts := fields.DetailParts(); len(parts) != 1 || parts[0] != "title: req" {
		t.Errorf("field details generic view = %q, want [\"title: req\"]", parts)
	}
}

// The generic value renderer must not drop any shape — the property the
// adopted implementation was chosen for.
func TestDetailValueRendersEveryShape(t *testing.T) {
	env, ok := Parse([]byte(`{"error":{"code":"c","message":"m","details":{` +
		`"reasons":["a","b"],` +
		`"duplicate_of":"post-1",` +
		`"count":7,` +
		`"flag":true,` +
		`"nested":{"rule":"weighted","index":2},` +
		`"list":[1,2]}}}`))
	if !ok {
		t.Fatal("Parse declined")
	}
	got := strings.Join(env.DetailParts(), " | ")
	for _, want := range []string{
		"reasons: a; b",        // []string joins
		"duplicate_of: post-1", // string loses its quotes
		"count: 7",
		"flag: true",
		`nested: {"rule":"weighted","index":2}`, // compact JSON
		"list: [1,2]",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("DetailParts missing %q\n got: %s", want, got)
		}
	}
	// Sorted by key, so the line is deterministic across runs.
	if !strings.HasPrefix(got, "count: 7 | duplicate_of: post-1 | flag: true") {
		t.Errorf("parts are not key-sorted: %s", got)
	}
}
