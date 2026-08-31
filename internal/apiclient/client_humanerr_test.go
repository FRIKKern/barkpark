package apiclient

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// humanAPIError renders the server envelope as one human line; unknown
// shapes clamp the raw body instead of swallowing it.
func TestHumanAPIError(t *testing.T) {
	err := humanAPIError(422, []byte(`{"error":{"code":"validation_failed","message":"task content failed validation","details":{"priority":["must be an integer 0..4, got \"3\""]},"request_id":"x"}}`))
	want := `task content failed validation — priority: must be an integer 0..4, got "3"`
	if err.Error() != want {
		t.Errorf("human error = %q, want %q", err.Error(), want)
	}

	err = humanAPIError(500, []byte("<html>gateway puke</html>"))
	if !strings.Contains(err.Error(), "error 500") || !strings.Contains(err.Error(), "gateway puke") {
		t.Errorf("fallback should clamp raw body, got %q", err.Error())
	}

	// A non-ASCII fallback body longer than the 200-char clamp must be cut on a
	// rune boundary — byte slicing would sever a multi-byte rune and emit
	// invalid UTF-8 to the status bar / logs.
	err = humanAPIError(503, []byte(strings.Repeat("æ", 300)))
	if !utf8.ValidString(err.Error()) {
		t.Errorf("clamped fallback must stay valid UTF-8, got %q", err.Error())
	}
	if !strings.HasSuffix(err.Error(), "…") {
		t.Errorf("clamped fallback should end with ellipsis, got %q", err.Error())
	}
}

// TestHumanAPIErrorNonFlatDetails covers the class of envelope the old
// map[string][]string-typed Details silently swallowed: any `details` shape
// other than validation_failed's flat {field:[reasons]} failed json.Unmarshal
// (string/object/array into []string), tripped the `== nil` guard, and the
// whole code+message+details payload fell through to the raw
// `error <status>: <body>` dump. With Details as json.RawMessage the code,
// message, and detail values all survive.
//
// MUTATION PROOF: reverting humanAPIError's Details field to
// `map[string][]string` (and dropping the two helper functions for the old
// inline map-range) makes this test RED. json.Unmarshal of the WHOLE env
// fails on the duplicate_of/resource_conflict shapes below (a string/object
// value into []string), so env.Error.Code/Message/Details all stay zero, the
// `(env.Error.Code != "" || env.Error.Message != "")` guard is false, and
// humanAPIError falls all the way through to the raw `error 409: <body>`
// dump. Plain strings.Contains on that raw dump would still spot every token
// below (it's just echoing the input JSON back), so each assertion here
// additionally requires the structured "message — key: value" rendering
// shape and REJECTS the raw-dump markers ("error 409:" prefix, a literal
// `{"error"` substring) — exactly the distinction this task's fix is about.
// Verified red against the pre-fix map[string][]string shape (stashed
// client.go, test file untouched): both subtests failed the
// strings.HasPrefix(err.Error(), "error 409:") / strings.Contains(..., `{"error"`)
// checks because the raw dump WAS what came back. Restoring json.RawMessage
// greens it again.
func TestHumanAPIErrorNonFlatDetails(t *testing.T) {
	assertStructured := func(t *testing.T, err error, wantContains ...string) {
		t.Helper()
		msg := err.Error()
		if strings.HasPrefix(msg, "error 409:") {
			t.Fatalf("error %q is the raw-dump fallback, not the structured rendering", msg)
		}
		if strings.Contains(msg, `{"error"`) {
			t.Fatalf("error %q leaked the raw JSON envelope instead of rendering it", msg)
		}
		for _, want := range wantContains {
			if !strings.Contains(msg, want) {
				t.Errorf("error %q, want it to contain %q", msg, want)
			}
		}
	}

	// duplicate_of: details is a bare string, not {field:[reasons]}.
	err := humanAPIError(409, []byte(`{"error":{"code":"duplicate_of","message":"a published document already uses this slug","details":{"duplicate_of":"post-1"}}}`))
	assertStructured(t, err, "a published document already uses this slug", "duplicate_of: post-1")

	// resource_conflict: details.conflicts is an array of objects.
	err = humanAPIError(409, []byte(`{"error":{"code":"resource_conflict","message":"file resources already held","details":{"conflicts":[{"doc_id":"task-abc","worker":"build-lane-j","resources":["internal/cli/run.go"]}]}}}`))
	assertStructured(t, err, "file resources already held", "task-abc", "build-lane-j", "internal/cli/run.go")
}

// TestHumanAPIErrorValidationFailedUnchanged pins the flat validation_failed
// rendering to the EXACT pre-fix message, across multiple fields, so the
// json.RawMessage switch cannot regress the one shape the old typed map did
// handle. Key order must stay deterministic (sorted).
func TestHumanAPIErrorValidationFailedUnchanged(t *testing.T) {
	err := humanAPIError(422, []byte(`{"error":{"code":"validation_failed","message":"task content failed validation","details":{"priority":["must be an integer 0..4, got \"3\""],"title":["can't be blank"]}}}`))
	want := `task content failed validation — priority: must be an integer 0..4, got "3" · title: can't be blank`
	if err.Error() != want {
		t.Errorf("human error = %q, want %q", err.Error(), want)
	}
}
