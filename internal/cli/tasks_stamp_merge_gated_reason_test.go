package cli

import (
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// pds-bl-merge-gated-override-carries-no-reason.
//
// `--merge-gated` is the ONE escape from the merge-gate refusal, and while it
// was a bare boolean it cost one word and recorded nothing: a reflex override
// and a deliberate one were byte-identical on the record, because the record was
// empty either way. The fix is that the flag carries a REASON, the CLI refuses a
// bare one before anything is sent, and the reason rides the POST so the server
// can persist it beside the stamp.
//
// EVERY TEST HERE IS A DETECTOR. Deleting the reason requirement reds
// TestTaskStampExecute_BareMergeGatedRefusedBeforeSend; forwarding a bare
// boolean instead of the reason reds
// TestTaskStampExecute_MergeGatedReasonRidesThePost; and
// TestStampMergeGateFallback_RefusalSetUnchangedByTheReason is the
// coverage-unchanged control — the refusal SET is frozen and the reason moves
// nothing into it or out of it.

// THE PRIMARY DETECTOR (criterion 0). A bare `--merge-gated` is refused with a
// usage-grade message that names what to supply, and NOTHING is sent. Delete
// the refusal in runTaskStamp and this reds twice over: exit exitOK instead of
// exitValidation, and hits == 1 instead of 0.
func TestTaskStampExecute_BareMergeGatedRefusedBeforeSend(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated",
	})
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; a bare override must be refused BEFORE sending", n)
	}
	// Usage-grade: it must name the flag AND the thing to supply.
	for _, want := range []string{"--merge-gated", "REASON", "stamp_overrides"} {
		if !strings.Contains(out, want) {
			t.Errorf("refusal does not name %q; got:\n%s", want, out)
		}
	}
}

// The blank spellings are the same refusal: an empty inline value and a flag
// whose "reason" is the next FLAG both leave the override unexplained.
func TestTaskStampExecute_BlankMergeGatedReasonsRefused(t *testing.T) {
	for _, c := range []struct {
		name string
		tail []string
	}{
		{"empty inline", []string{"--merge-gated="}},
		{"whitespace inline", []string{"--merge-gated=   "}},
		{"next token is a flag", []string{"--merge-gated", "--met"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			hits := stampTestServer(t)
			args := append([]string{
				"task", "stamp", "bp-task-x", "w", "1",
				"--criterion", "6", "--met", "--evidence", "e",
				"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
			}, c.tail...)
			out, code := captureExecuteCode(t, args)
			if code != exitValidation {
				t.Fatalf("exit = %d, want exitValidation; out:\n%s", code, out)
			}
			if n := atomic.LoadInt32(hits); n != 0 {
				t.Fatalf("stamp POST fired %d times; want 0", n)
			}
		})
	}
}

// THE PERSISTENCE HALF, client side (criterion 1). The reason must reach the
// server verbatim — the server cannot persist what it never receives. A
// mutation that keeps forwarding `merge-gated` as a bare boolean reds here.
func TestTaskStampExecute_MergeGatedReasonRidesThePost(t *testing.T) {
	var gotQuery string
	hits := stampTestServerQuery(t, &gotQuery)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated", "PR #123 merged to main as abc1234; I am the lead",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if !strings.Contains(gotQuery, "merge-gated=PR+%23123+merged+to+main+as+abc1234%3B+I+am+the+lead") {
		t.Errorf("the reason did not reach the server intact; query was %q", gotQuery)
	}
}

// SERVER-SKEW ARM. A server that still declares the reason-less BOOL flag must
// receive the bare flag and NOT the reason token — which it would bind as a
// positional and reject. The reason is still REQUIRED of the caller: the cost
// of the override does not depend on how old the server is.
func TestTaskStampExecute_ReasonlessServerGetsBareFlagOnly(t *testing.T) {
	var gotQuery string
	hits := stampTestServerWith(t, stampStoreHonest, reasonlessStampManifest, &gotQuery)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated", "PR #123 merged to main as abc1234",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if !strings.Contains(gotQuery, "merge-gated=true") {
		t.Errorf("bool-declaring server should have received the bare flag; query was %q", gotQuery)
	}
	// And a bare override is still refused against that same server.
	hits2 := stampTestServerWith(t, stampStoreHonest, reasonlessStampManifest, nil)
	_, code2 := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated",
	})
	if code2 != exitValidation || atomic.LoadInt32(hits2) != 0 {
		t.Fatalf("bare override against a reason-less server: exit %d, hits %d; want exitValidation, 0",
			code2, atomic.LoadInt32(hits2))
	}
}

// commandFlagType is the three-way probe the routing above turns on. Presence
// alone stopped being enough the moment the flag grew a value.
func TestCommandFlagType(t *testing.T) {
	cmd := stampCommandWithGatedType("string")
	if got := commandFlagType(cmd, "merge-gated"); got != "string" {
		t.Errorf("string flag read as %q", got)
	}
	if got := commandFlagType(stampCommandWithGatedType("bool"), "merge-gated"); got != "bool" {
		t.Errorf("bool flag read as %q", got)
	}
	if got := commandFlagType(cmd, "nope"); got != "" {
		t.Errorf("undeclared flag read as %q, want \"\"", got)
	}
	// An empty declared type is the manifest's own default: a string flag.
	if got := commandFlagType(stampCommandWithGatedType(""), "merge-gated"); got != "string" {
		t.Errorf("type-less declared flag read as %q, want string", got)
	}
}

// COVERAGE IS PROVEN UNCHANGED (criterion 2), CLI half. The refusal SET is the
// population this test freezes: for every wording, with NO override, the legacy
// tripwire's verdict is pinned. The reason requirement touches only the ESCAPE,
// so the same wordings are blocked before and after and NOTHING becomes
// stampable that was not stampable already — a mutation that narrowed
// isMergeGatedText (the refuted fix this row was split off from) reds here.
func TestStampMergeGateFallback_RefusalSetUnchangedByTheReason(t *testing.T) {
	population := []string{
		"[MERGE-GATED] PR merged to main (LEAD closes this criterion on merge).",
		"final row [MERGE-GATED — the lead closes this]",
		"row merge-gated by the lead",
		"MERGE GATED, spelled with a space",
		"a criterion that merely mentions the MERGE-GATED convention in passing",
		"CGO_ENABLED=0 go test ./internal/cli/... green, counts quoted.",
		"the reason is persisted on the row beside the stamp",
		"",
	}
	// Frozen: index i is blocked iff blocked[i]. This is the SAME set the
	// tripwire refused before the reason existed.
	blocked := []bool{true, true, true, true, true, false, false, false}

	var got []bool
	for _, text := range population {
		got = append(got, stampMergeGateFallback(stampArgs{met: true, criterionText: text}))
	}
	if !reflect.DeepEqual(got, blocked) {
		t.Fatalf("the refusal set MOVED: %v\n want %v", got, blocked)
	}

	// And the escape: a reason-carrying override releases exactly the blocked
	// rows and invents no new permit on the unblocked ones.
	for i, text := range population {
		sa := stampArgs{met: true, criterionText: text, mergeGated: true, mergeGatedReason: "PR #1 merged"}
		if stampMergeGateFallback(sa) {
			t.Errorf("%q: a signed override must release the tripwire (row %d)", text, i)
		}
	}
}

// stampCommandWithGatedType is a manifest command declaring --merge-gated with
// the given type ("" declares it with no type at all).
func stampCommandWithGatedType(typ string) manifest.Command {
	return manifest.Command{Flags: []manifest.Flag{
		{Name: "met", Type: "bool"},
		{Name: "merge-gated", Type: typ},
	}}
}
