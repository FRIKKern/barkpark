package cloudclient

// site_deployment_refusal_phase_test.go pins the DECODE half of the box
// refusal's PHASE (dr-w15-s3-followup-decode-refusal-phase; producer slice
// dr-w15-s3-emit-the-two-corpses).
//
// `deployment_json/1` emits `refusal_phase` — "start" when the TRIGGER was
// refused and no build ever began, "poll" when a beat of a build ALREADY
// RUNNING was refused and a build died mid-flight — and `SiteDeployment`
// declared no tag for it, so `json.Unmarshal` dropped it in silence. Same class,
// very different blast radius, and the failure taxonomy deliberately does not
// split on it, so this key is the ONLY way the phase reaches a reader.
//
// THE POINTER IS THE POINT, for the reason the FailureCode/FailureMessage pair
// next door is *string. The producer sends null on every row that is NOT a box
// refusal and refuses to coerce that to "start" — "this was not a refusal" and
// "this was refused at trigger time" are different sentences. A plain string
// decodes both to "" and the render can no longer tell them apart. Flip the
// field to a plain string and the nil arms below stop compiling, which is what
// a type-level mutation looks like when the test depends on the type.
//
// HONEST LIMIT, carried from the producer: cloud-db-1 holds ZERO poll-phase rows
// all-time against 14,848 start-phase ones. This decoder is a TRIPWIRE for the
// first poll refusal, not a live discriminator — which is exactly why the "poll"
// case below is a fixture rather than a corpus row.

import (
	"encoding/json"
	"testing"
)

func TestSiteDeploymentRefusalPhaseDecodes(t *testing.T) {
	phase := func(s string) *string { return &s }

	cases := []struct {
		name string
		body string
		want *string
	}{
		{
			// THE CORPUS ROW, 14,848 of them: the trigger was refused, no build
			// ever started.
			name: "start decodes",
			body: `{"id":"dep-1","status":"failed","failure_reason":"the instance refused the deploy (HTTP 503): no runner available","refusal_phase":"start"}`,
			want: phase("start"),
		},
		{
			// THE TRIPWIRE ROW, zero of them on cloud-db-1 today. A build that was
			// already running got killed by a refused poll.
			name: "poll decodes",
			body: `{"id":"dep-2","status":"failed","failure_reason":"the instance refused the deploy (HTTP 500): boom","refusal_phase":"poll"}`,
			want: phase("poll"),
		},
		{
			// The overwhelming majority of FAILED rows: not a box refusal at all.
			// The producer sends null and never coerces it to "start".
			name: "null stays nil, never start",
			body: `{"id":"dep-3","status":"failed","failure_reason":"BUILD failed (exit 12): boom","refusal_phase":null}`,
			want: nil,
		},
		{
			// A pre-W15-S3 row: the control plane never sent the key at all.
			// Absent and null must land on the same nil, not on different states.
			name: "key absent entirely stays nil",
			body: `{"id":"dep-4","status":"failed","failure_reason":"BUILD failed (exit 12): boom"}`,
			want: nil,
		},
		{
			// A LIVE row carries no refusal of any kind, and must not acquire one.
			name: "a live row has no phase",
			body: `{"id":"dep-5","status":"live","refusal_phase":null}`,
			want: nil,
		},
		{
			// THE DISCRIMINATION, as a case: an empty string on the wire is a
			// value the producer sent, and it decodes to a non-nil pointer to "".
			// Under a plain-string field this row and the nil rows above are the
			// same "", and nothing downstream can separate them again.
			name: "empty string is a value, not an absence",
			body: `{"id":"dep-6","status":"failed","refusal_phase":""}`,
			want: phase(""),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var d SiteDeployment
			if err := json.Unmarshal([]byte(tc.body), &d); err != nil {
				t.Fatalf("decode: %v", err)
			}
			// assertHalf is site_deployment_failure_halves_test.go's comparator and
			// it keeps the nil-vs-empty distinction load-bearing in the failure
			// message itself — the same property this field needs.
			assertHalf(t, "refusal_phase", d.RefusalPhase, tc.want)
		})
	}
}

// TestSiteDeploymentRefusalPhaseIsDeclared is the guard against the exact defect
// this slice closes: the key rode the wire for a whole wave and the struct never
// named it, so `json.Unmarshal` threw it away and NOTHING went red. A decode
// test alone cannot say that — it would pass just as happily against a struct
// that decoded the key under some other name. This one asserts the wire spelling
// the producer actually sends.
func TestSiteDeploymentRefusalPhaseIsDeclared(t *testing.T) {
	// The producer's own spelling, from `deployment_json/1`. If this literal and
	// the struct tag ever disagree, the field is decoding a key nobody emits.
	const wireKey = `{"refusal_phase":"poll"}`

	var d SiteDeployment
	if err := json.Unmarshal([]byte(wireKey), &d); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if d.RefusalPhase == nil {
		t.Fatal("SiteDeployment does not decode the `refusal_phase` key the control " +
			"plane emits — json.Unmarshal drops an unmodelled key in silence, which " +
			"is the whole defect dr-w15-s3-followup-decode-refusal-phase closes")
	}
	if *d.RefusalPhase != "poll" {
		t.Fatalf("refusal_phase decoded %q, want poll", *d.RefusalPhase)
	}

	// THE CONTROL. A key the payload does NOT carry must not arrive with a value
	// — otherwise the assertion above would pass against a struct that filled the
	// field from somewhere else, and the test would be measuring nothing.
	var empty SiteDeployment
	if err := json.Unmarshal([]byte(`{"id":"dep-control"}`), &empty); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if empty.RefusalPhase != nil {
		t.Fatalf("a payload with no refusal_phase produced %q — the field is not "+
			"reading the wire", *empty.RefusalPhase)
	}
}
