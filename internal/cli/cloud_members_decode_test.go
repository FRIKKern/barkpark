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
// parse: STDOUT is byte-for-byte what the server sent. If the stdout assertion
// here ever reds, the fix has leaked into the contract.
//
// AMENDED for task-71c728c110bb4911. This test used to assert exit 0 as well,
// which pinned the half of the behaviour that was the defect: a `members` value
// that is not an array is not a roster, and a script reading `$?` was told the
// read succeeded. The bytes stay verbatim (that decision, from #15501, is
// correct and is NOT reversed); only the exit status changed.
func TestMembersDecodeSkewKeepsJSONVerbatim(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, `{"members":{"user_id":"u-1"}}`},
		membersRoute{200, `{"invitations":[]}`})

	out, _, code := runMembers(t, "json", false)

	if code == exitOK {
		t.Fatalf("a non-array `members` value exited 0 — a script's seat count is now the object's KEY count:\n%s", out)
	}
	if !strings.Contains(out, `"members":{"user_id":"u-1"}`) {
		t.Fatalf("the JSON path reshaped the contract bytes:\n%s", out)
	}
}

// TestMembersNonArrayJSONRefusesWithoutReshaping is the positive arm of
// task-71c728c110bb4911, in one test holding BOTH halves that pull against each
// other: the exit status must carry the refusal AND stdout must stay the
// control-plane bytes. A fix that normalises `members` to [] passes the first
// and fails the second; a fix that only logs passes the second and fails the
// first.
func TestMembersNonArrayJSONRefusesWithoutReshaping(t *testing.T) {
	newMembersServer(t,
		membersRoute{200, `{"members":{"user_id":"u-1"}}`},
		membersRoute{200, `{"invitations":[]}`})

	stdout, stderr, code := runMembers(t, "json", false)

	if code == exitOK {
		t.Fatalf("a non-array `members` value exited 0:\nstdout:%s\nstderr:%s", stdout, stderr)
	}
	// STDOUT IS THE CONTRACT: verbatim bytes, unreshaped, in the refusal case too.
	if !strings.Contains(stdout, `"members":{"user_id":"u-1"}`) {
		t.Fatalf("the refusal RESHAPED the contract bytes — the exit status carries the signal, not a rewritten document:\n%s", stdout)
	}
	if strings.Contains(stdout, `"members":[]`) {
		t.Fatalf("the refusal normalised a non-array roster to an empty array — that is a second, drifting definition of the contract:\n%s", stdout)
	}
	// The diagnostic is on STDERR and names the shape that arrived.
	if !strings.Contains(stderr, "object") {
		t.Fatalf("the diagnostic did not name the SHAPE the control plane sent:\n%s", stderr)
	}
	if !strings.Contains(stderr, "members") {
		t.Fatalf("the diagnostic did not name WHICH value was not an array:\n%s", stderr)
	}
	if strings.Contains(stdout, "bp:") {
		t.Fatalf("the diagnostic leaked onto STDOUT and corrupted the document:\n%s", stdout)
	}
}

// TestMembersNonArrayShapesAllRefuse walks the non-array shapes a drifting
// control plane can send. An object is the filed one; a string and a number are
// the same violation wearing different bytes, and each must name ITS OWN shape —
// a diagnostic that says "object" for a string has stopped measuring.
func TestMembersNonArrayShapesAllRefuse(t *testing.T) {
	for _, tc := range []struct{ name, body, shape string }{
		{"object", `{"members":{"user_id":"u-1"}}`, "object"},
		{"string", `{"members":"u-1,u-2"}`, "string"},
		{"number", `{"members":2}`, "number"},
		{"boolean", `{"members":true}`, "boolean"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newMembersServer(t, membersRoute{200, tc.body}, membersRoute{200, `{"invitations":[]}`})

			stdout, stderr, code := runMembers(t, "json", false)

			if code == exitOK {
				t.Fatalf("a %s `members` value exited 0:\nstdout:%s", tc.name, stdout)
			}
			if !strings.Contains(stderr, tc.shape) {
				t.Fatalf("the diagnostic did not name the shape %q:\n%s", tc.shape, stderr)
			}
		})
	}
}

// TestMembersGenuinelyEmptyJSONStaysZero is the NEGATIVE ARM on the MACHINE
// path: the three shapes a real empty roster arrives in must still exit 0 and
// still emit []. A fix that reddens every empty roster is not an improvement.
func TestMembersGenuinelyEmptyJSONStaysZero(t *testing.T) {
	for _, tc := range []struct{ name, body string }{
		{"empty array", `{"members":[]}`},
		{"null", `{"members":null}`},
		{"key absent", `{"ok":true}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			newMembersServer(t, membersRoute{200, tc.body}, membersRoute{200, `{"invitations":[]}`})

			stdout, stderr, code := runMembers(t, "json", false)

			if code != exitOK {
				t.Fatalf("a genuinely empty roster exited %d — a false alarm is not an improvement:\nstdout:%s\nstderr:%s", code, stdout, stderr)
			}
			if !strings.Contains(stdout, `"members":[]`) {
				t.Fatalf("a genuinely empty roster lost its []:\n%s", stdout)
			}
			if stderr != "" {
				t.Fatalf("a genuinely empty roster wrote a diagnostic:\n%s", stderr)
			}
		})
	}
}

// TestMembersRealArrayJSONStaysZero is the other half of the negative arm: a
// POPULATED, contract-shaped roster is untouched — same bytes, same exit 0, no
// diagnostic. Without it, a check that reds on every non-empty answer would
// still pass the empty-roster arm above.
func TestMembersRealArrayJSONStaysZero(t *testing.T) {
	newMembersServer(t, membersRoute{200, membersBody}, membersRoute{200, invitationsBody})

	stdout, stderr, code := runMembers(t, "json", false)

	if code != exitOK {
		t.Fatalf("a contract-shaped roster exited %d:\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	if stderr != "" {
		t.Fatalf("a contract-shaped roster wrote a diagnostic:\n%s", stderr)
	}
	if !strings.Contains(stdout, "owner@team.io") {
		t.Fatalf("the roster bytes did not survive:\n%s", stdout)
	}
}
