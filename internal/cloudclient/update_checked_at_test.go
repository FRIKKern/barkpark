package cloudclient

// update_checked_at_test.go pins the cch-w65-bl decode: `update_checked_at` is a
// `*string`, so a control plane that recorded NO CHECK can no longer be read as
// a box whose check time happens to be the empty string.
//
// WHY THE SHAPE MATTERS, measured rather than argued. cch-w65-s2 made the column
// honest: `@unclocked_reasons` in the plane's registry.ex omits the stamp on the
// three of nine unknown rungs that return before a request is built
// (`:no_admin_token`, `:decrypt_failed`, `:not_live`), so those rows serve an
// explicit `"update_checked_at": null`. While the field was a plain `string`,
// that null and an older plane's OMITTED key both landed as `""` and the
// distinction was destroyed at decode — see TestUpdateCheckedAtNullAndAbsentBothNil
// below, which is the arm that would have failed to exist.

import (
	"encoding/json"
	"testing"
)

// row builds a fleet row with the given update_checked_at fragment spliced in
// (or nothing at all, for the older-CP arm).
func clockRow(fragment string) string {
	base := `{"id":"i1","name":"n","slug":"n","host":"h","health_status":"unknown","agent_status":"offline","update_state":"unknown"`
	if fragment == "" {
		return base + `}`
	}
	return base + `,"update_checked_at":` + fragment + `}`
}

func TestUpdateCheckedAtDecodeTriState(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		wantPtr     *string // nil = must decode to nil
		wantMissing bool
	}{
		{
			name:        "a real check time decodes to a present pointer",
			body:        clockRow(`"2026-09-15T09:17:05.499647Z"`),
			wantPtr:     strPtr("2026-09-15T09:17:05.499647Z"),
			wantMissing: false,
		},
		{
			name: "an explicit null is NO CHECK RECORDED, not an empty time",
			body: clockRow(`null`),
			// nil pointer, but the key WAS on the wire: the plane measured that
			// it never spoke to this box (one of the three unclocked rungs).
			wantPtr:     nil,
			wantMissing: false,
		},
		{
			name:        "an older control plane omits the key entirely",
			body:        clockRow(``),
			wantPtr:     nil,
			wantMissing: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var b Barkpark
			if err := json.Unmarshal([]byte(tc.body), &b); err != nil {
				t.Fatalf("decode: %v", err)
			}
			switch {
			case tc.wantPtr == nil && b.UpdateCheckedAt != nil:
				t.Fatalf("UpdateCheckedAt = %q, want nil — a plane that recorded no check must not hand a consumer a string", *b.UpdateCheckedAt)
			case tc.wantPtr != nil && b.UpdateCheckedAt == nil:
				t.Fatalf("UpdateCheckedAt = nil, want %q", *tc.wantPtr)
			case tc.wantPtr != nil && *b.UpdateCheckedAt != *tc.wantPtr:
				t.Fatalf("UpdateCheckedAt = %q, want %q", *b.UpdateCheckedAt, *tc.wantPtr)
			}
			if b.UpdateCheckedAtMissing != tc.wantMissing {
				t.Fatalf("UpdateCheckedAtMissing = %v, want %v", b.UpdateCheckedAtMissing, tc.wantMissing)
			}
		})
	}
}

// TestUpdateCheckedAtNullAndAbsentBothNil is the CONFLATION arm stated as an
// assertion: at the Go VALUE level the two causes are one nil — that is the
// deliberate house rule AutoupdateEnabled and CommitDistance already follow — and
// the only thing that keeps them apart is the wire-presence flag. If someone
// deletes the `UpdateCheckedAtMissing` line from Barkpark.UnmarshalJSON this test
// is what reds, and it reds naming the fact that was lost.
func TestUpdateCheckedAtNullAndAbsentBothNil(t *testing.T) {
	var explicitNull, older Barkpark
	if err := json.Unmarshal([]byte(clockRow(`null`)), &explicitNull); err != nil {
		t.Fatalf("decode null row: %v", err)
	}
	if err := json.Unmarshal([]byte(clockRow(``)), &older); err != nil {
		t.Fatalf("decode older-CP row: %v", err)
	}
	if explicitNull.UpdateCheckedAt != nil || older.UpdateCheckedAt != nil {
		t.Fatalf("both causes must read nil: null=%v older=%v", explicitNull.UpdateCheckedAt, older.UpdateCheckedAt)
	}
	if explicitNull.UpdateCheckedAtMissing == older.UpdateCheckedAtMissing {
		t.Fatalf("an explicit null (the plane measured 'never checked') and an omitted key " +
			"(the plane is too old to say) must be DISTINGUISHABLE — UpdateCheckedAtMissing " +
			"reads the same for both, so the wire-level fact was destroyed at decode")
	}
}

// TestUpdateCheckedAtNullClearsAStaleValue is the reused-struct arm, and it
// records a CORRECTION to the mechanism cch-w65-bl was filed on. The filing says
// "Go's json.Unmarshal of a JSON null into a string field is a NO-OP — a preset
// field survives the unmarshal unchanged". That is true of encoding/json in
// general and FALSE of this type: Barkpark has a custom UnmarshalJSON (added for
// queued_deploy_age_seconds) whose last act is `*b = Barkpark(decoded)`, a
// wholesale overwrite from a fresh value. So on the pre-fix tree a preset clock
// did NOT survive — it was flattened to "", which is the same wrong answer by a
// different route. The bug the row names is real; the mechanism it names is not
// the one operating. Either way a decode must not leave a previous poll's clock
// standing, and this pins that.
func TestUpdateCheckedAtNullClearsAStaleValue(t *testing.T) {
	sentinel := "1999-01-01T00:00:00Z"
	b := Barkpark{UpdateCheckedAt: &sentinel}
	if err := json.Unmarshal([]byte(clockRow(`null`)), &b); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if b.UpdateCheckedAt != nil {
		t.Fatalf("a null clock left a stale value standing: %q — a consumer would read another poll's time as this one's", *b.UpdateCheckedAt)
	}
}

func strPtr(s string) *string { return &s }
