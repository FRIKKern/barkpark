package cli

// cloud_members_decode_test.go is the REFUSAL-vs-EMPTY arm of `bp cloud members`.
//
// The defect: TeamMembers/TeamInvitations swallowed the INNER array decode
// (`_ = json.Unmarshal(env.Members, &members)`), so a 200 carrying a shape the
// row struct cannot read left the slice nil and the human view printed
// "(no members)" — byte-identical to a genuinely empty roster, at exit 0. A
// per-FIELD type skew is the quieter half: encoding/json KEEPS the element and
// blanks only the bad field, so the table shows a row with a dash where a real
// value was.
//
// Both arms are required. A reader that shouts on every zero has replaced a
// false empty with a false alarm, so the negative arms below pin that an absent
// key, a null, and a real `[]` still read as a plain, silent zero.

import (
	"strings"
	"testing"
)

// TestMembersShapeSkewRefusesInsteadOfEmpty — the array is not an array of
// members. Before the fix: "(no members)", exit 0. After: a named refusal and a
// non-zero exit.
func TestMembersShapeSkewRefusesInsteadOfEmpty(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, `{"members":{"user_id":"u-1","email":"owner@team.io","role":"owner"}}`},
		membersRoute{200, invitationsBody})

	out, _, code := runMembers(t, "text", false)

	if code == exitOK {
		t.Fatalf("an unreadable roster exited 0 — a refused read is indistinguishable from an empty team.\n%s", out)
	}
	if strings.Contains(out, "(no members)") {
		t.Fatalf("an unreadable roster rendered as an EMPTY roster:\n%s", out)
	}
	if !strings.Contains(out, "Could not read the member roster") {
		t.Fatalf("no named refusal in the output:\n%s", out)
	}
	if !strings.Contains(out, "cannot unmarshal object") {
		t.Fatalf("the refusal did not name WHAT failed to decode:\n%s", out)
	}
}

// TestMembersFieldTypeSkewIsNotSilent — a type error never shortens a Go slice:
// the element survives with a BLANKED field, so a table alone looks measured.
// The note is the only thing that says the cells are not the contract.
func TestMembersFieldTypeSkewIsNotSilent(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, `{"members":[{"user_id":"u-1","email":42,"role":"owner"}]}`},
		membersRoute{200, invitationsBody})

	out, _, code := runMembers(t, "text", false)

	if code == exitOK {
		t.Fatalf("a blanked-out roster cell exited 0:\n%s", out)
	}
	if !strings.Contains(out, "Could not read the member roster") {
		t.Fatalf("a silently blanked field rendered as a measured roster:\n%s", out)
	}
}

// TestInvitationsShapeSkewIsNotNonePending — invitations never fail the whole
// view (they are admin-gated by design), but an unparseable list must not read
// as "No pending invitations."
func TestInvitationsShapeSkewIsNotNonePending(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, membersBody},
		membersRoute{200, `{"invitations":"soon"}`})

	out, _, _ := runMembers(t, "text", false)

	if strings.Contains(out, "No pending invitations.") {
		t.Fatalf("an unreadable invitation list rendered as NONE PENDING:\n%s", out)
	}
	if !strings.Contains(out, "Could not read pending invitations") {
		t.Fatalf("no named refusal for invitations:\n%s", out)
	}
	if !strings.Contains(out, "owner@team.io") {
		t.Fatalf("the roster stopped rendering — invitations must degrade, not fail the view:\n%s", out)
	}
}

// TestMembersGenuinelyEmptyStillReadsAsZero is the NEGATIVE arm, in the three
// shapes a real empty result arrives in. Each must stay a plain, silent zero at
// exit 0 — the fix is worthless if every zero becomes suspicious.
func TestMembersGenuinelyEmptyStillReadsAsZero(t *testing.T) {
	for _, tc := range []struct{ name, body string }{
		{"empty array", `{"members":[]}`},
		{"null", `{"members":null}`},
		{"key absent", `{"ok":true}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newMembersServer(t, membersRoute{200, tc.body}, membersRoute{200, `{"invitations":[]}`})

			out, _, code := runMembers(t, "text", false)

			if code != exitOK {
				t.Fatalf("a genuinely empty roster exited %d — a false alarm is not an improvement:\n%s", code, out)
			}
			if !strings.Contains(out, "(no members)") {
				t.Fatalf("a genuinely empty roster lost its zero:\n%s", out)
			}
			if strings.Contains(out, "Could not read") {
				t.Fatalf("a genuinely empty roster was reported as unreadable:\n%s", out)
			}
			if !strings.Contains(out, "No pending invitations.") {
				t.Fatalf("a genuinely empty invitation list lost its zero:\n%s", out)
			}
		})
	}
}

// TestMembersDecodeSkewKeepsJSONVerbatim — the machine path re-emits the
// control-plane BYTES (D4), so it is unaffected by OUR row structs failing to
// parse and stays exit 0. If this ever reds, the fix has leaked into the
// contract.
func TestMembersDecodeSkewKeepsJSONVerbatim(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, `{"members":{"user_id":"u-1"}}`},
		membersRoute{200, `{"invitations":[]}`})

	out, _, code := runMembers(t, "json", false)

	if code != exitOK {
		t.Fatalf("the verbatim JSON path should not be refused, got exit %d:\n%s", code, out)
	}
	if !strings.Contains(out, `"members":{"user_id":"u-1"}`) {
		t.Fatalf("the JSON path reshaped the contract bytes:\n%s", out)
	}
}
