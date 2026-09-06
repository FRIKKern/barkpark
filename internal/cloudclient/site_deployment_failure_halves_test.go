package cloudclient

// site_deployment_failure_halves_test.go pins the DECODE half of the unfused box
// refusal (task-f156b5e43bfbfe91; producer PR #16511).
//
// `deployment_json/1` emits `failure_code` and `failure_message` beside the
// byte-unchanged composite `failure_reason`. Both are null on every row that is
// not a box refusal, and null INDIVIDUALLY when the box sent only one half.
//
// The whole reason these fields are *string and not string is the null. A plain
// string decodes every one of those nulls to "", and `""` is indistinguishable
// from a code the box actually sent as empty — so the render loses the ability to
// say "this row records no typed code" and starts printing a bare em-dash over
// 14,000 non-refusal rows. This file is the tripwire on that: flip either field
// to a plain string and the nil arms below stop compiling, which is what a
// type-level mutation looks like when the test actually depends on the type.

import (
	"encoding/json"
	"testing"
)

func TestSiteDeploymentFailureHalvesDecode(t *testing.T) {
	code := func(s string) *string { return &s }

	cases := []struct {
		name     string
		body     string
		wantCode *string
		wantMsg  *string
	}{
		{
			// The overwhelming majority row: a deploy that failed for a reason
			// that was never a box refusal. Both keys are null on the wire.
			name:     "null both halves stays nil",
			body:     `{"id":"dep-1","status":"failed","failure_reason":"the build command exited non-zero","failure_code":null,"failure_message":null}`,
			wantCode: nil,
			wantMsg:  nil,
		},
		{
			// A pre-split row: the control plane never sent the keys at all.
			// Absent and null must land on the same nil, not on different states.
			name:     "keys absent entirely stays nil",
			body:     `{"id":"dep-2","status":"failed","failure_reason":"the instance refused the deploy (HTTP 400): E_NO_INDEX — the archive has no index.html at its root"}`,
			wantCode: nil,
			wantMsg:  nil,
		},
		{
			name:     "both halves present decode",
			body:     `{"id":"dep-3","status":"failed","failure_reason":"the instance refused the deploy (HTTP 400): E_ABSOLUTE_PATH — entry \"/quota/index.html\" is an absolute path — refused","failure_code":"E_ABSOLUTE_PATH","failure_message":"entry \"/quota/index.html\" is an absolute path — refused"}`,
			wantCode: code("E_ABSOLUTE_PATH"),
			wantMsg:  code(`entry "/quota/index.html" is an absolute path — refused`),
		},
		{
			// The box sent a code and no sentence. The message half stays nil —
			// NOT "", which would read as a sentence the box wrote and left blank.
			name:     "code only leaves message nil",
			body:     `{"id":"dep-4","status":"failed","failure_code":"already_running","failure_message":null}`,
			wantCode: code("already_running"),
			wantMsg:  nil,
		},
		{
			name:     "message only leaves code nil",
			body:     `{"id":"dep-5","status":"failed","failure_code":null,"failure_message":"the box is already running a deploy for this site"}`,
			wantCode: nil,
			wantMsg:  code("the box is already running a deploy for this site"),
		},
		{
			// THE DISCRIMINATION, stated as a case: an EMPTY STRING on the wire is
			// a value the box sent, and it decodes to a non-nil pointer to "".
			// Under a plain-string field this row and the null rows above are the
			// same "", and nothing downstream can tell them apart again.
			name:     "empty string is a value, not an absence",
			body:     `{"id":"dep-6","status":"failed","failure_code":"","failure_message":""}`,
			wantCode: code(""),
			wantMsg:  code(""),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var d SiteDeployment
			if err := json.Unmarshal([]byte(tc.body), &d); err != nil {
				t.Fatalf("decode: %v", err)
			}
			assertHalf(t, "failure_code", d.FailureCode, tc.wantCode)
			assertHalf(t, "failure_message", d.FailureMessage, tc.wantMsg)
		})
	}
}

// assertHalf compares a decoded half against what the wire said, keeping the
// nil-vs-empty distinction load-bearing in the failure message itself.
func assertHalf(t *testing.T, key string, got, want *string) {
	t.Helper()
	switch {
	case want == nil && got == nil:
		return
	case want == nil:
		t.Fatalf("%s: a null/absent key must decode nil, got a pointer to %q — "+
			"that is a value the payload never sent", key, *got)
	case got == nil:
		t.Fatalf("%s: the wire carried %q and it decoded to nil", key, *want)
	case *got != *want:
		t.Fatalf("%s: decoded %q, want %q", key, *got, *want)
	}
}
