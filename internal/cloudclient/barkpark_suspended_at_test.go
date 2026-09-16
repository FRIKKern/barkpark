package cloudclient

// barkpark_suspended_at_test.go pins the DECODE half of the billing-suspension
// stamp (task-85c531c2adbf0dff; producer slice cch-w54-bl, PR #14694).
//
// `barkpark_json/6` has emitted `suspended_at` beside `suspended` and
// `suspended_reason` since cch-w54-bl, and the `Barkpark` struct declared no tag
// for it, so `json.Unmarshal` dropped it in silence: every `bp cloud` reader
// could say a box was suspended and WHY but never SINCE WHEN. That was not
// missed — the payload census refused it as "newly unread (emitted, decoded by
// NOBODY)" the moment the key landed, and cch-w54-bl (fenced to cloud/) filed a
// KNOWN OPEN :unread allowlist row naming this task as its tracker rather than
// smuggling a Go edit past its scope. This decoder is what deletes that row.
//
// THE POINTER IS THE POINT, the same argument `SiteDeployment.RefusalPhase`
// makes next door (PR #18566). NULL MEANS NOT SUSPENDED, never "suspended at an
// unknown time": `Registry.unsuspend_barkpark/1` and the bulk resume clear
// suspended/suspended_reason/suspended_at together, so a live box never carries
// a stale stamp. A plain `string` collapses that null, a pre-cch-w54-bl plane's
// absent key, and a real RFC3339 stamp into one `""` and no reader downstream
// can take them apart again. Flip the field to a plain string and the nil arms
// below stop compiling — which is what a type-level mutation looks like when
// the test depends on the type.

import (
	"encoding/json"
	"testing"
)

func TestBarkparkSuspendedAtDecodes(t *testing.T) {
	at := func(s string) *string { return &s }

	cases := []struct {
		name string
		body string
		want *string
	}{
		{
			// A suspended box: the plane stamped the day billing cut it off.
			// `:utc_datetime_usec` on the producer side, so microseconds ride
			// along and must survive decode untouched.
			name: "a stamped suspension decodes",
			body: `{"id":"bp-1","name":"acme","suspended":true,` +
				`"suspended_reason":"billing: card declined",` +
				`"suspended_at":"2026-09-01T12:34:56.000000Z"}`,
			want: at("2026-09-01T12:34:56.000000Z"),
		},
		{
			// The overwhelming majority of rows: a LIVE box. The producer sends
			// an explicit null and must never be read as a suspension.
			name: "null on a live box stays nil",
			body: `{"id":"bp-2","name":"acme","suspended":false,` +
				`"suspended_reason":null,"suspended_at":null}`,
			want: nil,
		},
		{
			// A control plane older than cch-w54-bl never sent the key at all.
			// Absent and null must land on the same nil, not on different states.
			name: "key absent entirely stays nil",
			body: `{"id":"bp-3","name":"acme","suspended":false}`,
			want: nil,
		},
		{
			// THE DISCRIMINATION, as a case: an empty string on the wire is a
			// value the plane sent, and it decodes to a non-nil pointer to "".
			// Under a plain-string field this row and the two nil rows above are
			// the same "", and nothing downstream can separate them again.
			name: "empty string is a value, not an absence",
			body: `{"id":"bp-4","name":"acme","suspended":true,"suspended_at":""}`,
			want: at(""),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var b Barkpark
			if err := json.Unmarshal([]byte(tc.body), &b); err != nil {
				t.Fatalf("decode: %v", err)
			}
			switch {
			case tc.want == nil && b.SuspendedAt != nil:
				t.Fatalf("suspended_at = %q, want nil — nil and a stamp are "+
					"different sentences", *b.SuspendedAt)
			case tc.want != nil && b.SuspendedAt == nil:
				t.Fatalf("suspended_at = nil, want %q", *tc.want)
			case tc.want != nil && *b.SuspendedAt != *tc.want:
				t.Fatalf("suspended_at = %q, want %q", *b.SuspendedAt, *tc.want)
			}
		})
	}
}

// TestBarkparkSuspendedAtIsDeclared is the guard against the exact defect this
// slice closes: the key rode the wire from cch-w54-bl onward and the struct
// never named it, so `json.Unmarshal` threw it away and NOTHING in Go went red.
// A decode test alone cannot say that — it would pass just as happily against a
// struct that decoded the key under some other name. This one asserts the WIRE
// SPELLING the producer actually sends, taken from `barkpark_json/6` in
// cloud/lib/barkpark_cloud/web/router.ex (`suspended_at: bp.suspended_at`).
//
// Revert `json:"suspended_at"` to `json:"-"` and this reds.
func TestBarkparkSuspendedAtIsDeclared(t *testing.T) {
	const wireKey = `{"suspended_at":"2026-09-01T12:34:56.000000Z"}`

	var b Barkpark
	if err := json.Unmarshal([]byte(wireKey), &b); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if b.SuspendedAt == nil {
		t.Fatal("Barkpark does not decode the `suspended_at` key the control " +
			"plane emits — json.Unmarshal drops an unmodelled key in silence, " +
			"which is the whole defect task-85c531c2adbf0dff closes")
	}
	if *b.SuspendedAt != "2026-09-01T12:34:56.000000Z" {
		t.Fatalf("suspended_at decoded %q, want the stamp verbatim", *b.SuspendedAt)
	}

	// THE CONTROL. A key the payload does NOT carry must not arrive with a value
	// — otherwise the assertion above would pass against a struct that filled
	// the field from somewhere else, and the test would be measuring nothing.
	var empty Barkpark
	if err := json.Unmarshal([]byte(`{"id":"bp-control"}`), &empty); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if empty.SuspendedAt != nil {
		t.Fatalf("a payload with no suspended_at produced %q — the field is not "+
			"reading the wire", *empty.SuspendedAt)
	}
}
