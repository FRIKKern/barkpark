package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// fakeRevisionSource hands the reader exactly the revisions a test names, or
// the error it names. THE INJECTION IS THE POINT: the two conditions this
// command exists to tell apart — a store that answers null and a store that
// does not answer at all — cannot be asked of the real network inside a unit
// test, so a test built on a live client could only ever walk the happy path
// and would stay green with the split deleted.
type fakeRevisionSource struct {
	revs  []apiclient.Revision
	err   error
	calls int
}

func (f *fakeRevisionSource) Revisions(typeName, docID string, limit int) ([]apiclient.Revision, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	return f.revs, nil
}

func sp(s string) *string { return &s }

func rev(action string, a apiclient.Revision) apiclient.Revision {
	a.Action = action
	if a.Timestamp.IsZero() {
		a.Timestamp = time.Date(2026, 9, 17, 19, 15, 42, 0, time.UTC)
	}
	return a
}

// historyTestWriter captures the HUMAN rendering. newTestWriter's default
// globals resolve to json, and the three-state wording under test lives in the
// table view, so the shape is pinned here rather than inherited.
func historyTestWriter() (*writer, *bytes.Buffer, *bytes.Buffer) {
	out, stdout, stderr := newTestWriter()
	out.output = "table"
	return out, stdout, stderr
}

// ============================== ARM 1: THE SPLIT =============================

// TestAttributionSplitsTheTwoAbsences is THE ARM. Its subject IS the
// three-state split in classifyAttribution. Collapse the two absences — treat a
// nil column the same as a present-but-empty one, in either direction — and the
// matching case below reports the wrong state and this test reds.
func TestAttributionSplitsTheTwoAbsences(t *testing.T) {
	cases := []struct {
		name string
		in   apiclient.Revision
		want attributionState
	}{
		{
			// The LIVE production shape, measured 2026-09-17: every actor
			// column comes back JSON null. The store was never told who made
			// this mutation. UNMEASURED.
			name: "every column null is NOT STAMPED",
			in:   apiclient.Revision{},
			want: attrNotStamped,
		},
		{
			// A column that EXISTS and is empty. The store answered, and its
			// answer was nothing. This is a measurement and must not read as
			// the case above.
			name: "a present empty column is ANSWERED-EMPTY",
			in:   apiclient.Revision{ActorKind: sp("")},
			want: attrAnsweredEmpty,
		},
		{
			name: "several present empty columns are still ANSWERED-EMPTY",
			in:   apiclient.Revision{ActorKind: sp(""), ActorID: sp(""), ActorLabel: sp("")},
			want: attrAnsweredEmpty,
		},
		{
			name: "one valued column is STAMPED",
			in:   apiclient.Revision{ActorKind: sp("agent")},
			want: attrStamped,
		},
		{
			// A partial stamp is a real answer, not a half-absence: one
			// measured field beats three nulls.
			name: "a valued column beside nulls is STAMPED",
			in:   apiclient.Revision{ActorLabel: sp("cli-r21d-w5")},
			want: attrStamped,
		},
		{
			name: "a valued column beside an empty one is STAMPED",
			in:   apiclient.Revision{ActorKind: sp(""), ActorID: sp("tok_1")},
			want: attrStamped,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyAttribution(tc.in)
			if got.State != tc.want {
				t.Fatalf("classifyAttribution = %v, want %v", got.State, tc.want)
			}
		})
	}
}

// TestNotStampedContributesNoFields guards the OTHER direction of the same
// split: a null column must not be turned into a rendered `name=""` line, or
// the output would show the store answering where it never did.
func TestNotStampedContributesNoFields(t *testing.T) {
	a := classifyAttribution(apiclient.Revision{})
	if len(a.Fields) != 0 {
		t.Fatalf("a wholly unstamped revision rendered %d field(s): %v", len(a.Fields), a.Fields)
	}
	if !strings.Contains(renderAttributionFields(a), "UNMEASURED") {
		t.Fatalf("an unstamped revision did not say UNMEASURED: %q", renderAttributionFields(a))
	}
}

// ==================== ARM 2: A FAILED READ IS NOT AN EMPTY ONE ===============

// TestFailedReadIsNeverAnEmptyTimeline is the second arm. A store that does not
// answer must exit non-zero and say a measured failure occurred; it must never
// render the vocabulary of an empty-but-answered history.
func TestFailedReadIsNeverAnEmptyTimeline(t *testing.T) {
	src := &fakeRevisionSource{err: errors.New("history error 500: boom")}
	rep := fetchHistory(src, "task-b3045c0a79510f28", 50)

	if rep.Read {
		t.Fatalf("a failed read reported Read=true")
	}
	if len(rep.Revisions) != 0 {
		t.Fatalf("a failed read produced %d revision(s) — an unread store must never yield a list", len(rep.Revisions))
	}

	out, stdout, stderr := historyTestWriter()
	code := renderTaskHistory(out, "task-b3045c0a79510f28", rep)
	if code == exitOK {
		t.Fatalf("a failed read exited 0")
	}
	body := stdout.String() + stderr.String()
	if !strings.Contains(body, "MEASURED FAILURE") {
		t.Fatalf("a failed read did not announce a measured failure:\n%s", body)
	}
	if strings.Contains(body, "ANSWERED and recorded no mutations") {
		t.Fatalf("a failed read rendered the answered-empty wording:\n%s", body)
	}
}

// TestEmptyReadIsMeasuredEmpty is the QUIET CONTROL for the arm above: an
// honest store that answers with no revisions exits 0 and says the store
// answered. If this reds, the command has been made loud in the wrong
// direction.
func TestEmptyReadIsMeasuredEmpty(t *testing.T) {
	rep := fetchHistory(&fakeRevisionSource{revs: nil}, "task-x", 50)
	if !rep.Read {
		t.Fatalf("an honest empty read reported Read=false")
	}

	out, stdout, stderr := historyTestWriter()
	if code := renderTaskHistory(out, "task-x", rep); code != exitOK {
		t.Fatalf("an honest empty read exited %d, want %d", code, exitOK)
	}
	body := stdout.String() + stderr.String()
	if !strings.Contains(body, "ANSWERED and recorded no mutations") {
		t.Fatalf("an honest empty read did not say the store answered:\n%s", body)
	}
	if strings.Contains(body, "MEASURED FAILURE") {
		t.Fatalf("an honest empty read announced a failure:\n%s", body)
	}
}

// ===================== ARM 3: THE VERDICT IS MEASURED ========================

// TestIdentityVerdictIsMeasuredNotHardcoded drives the footer from three
// different inputs. A hardcoded "identity is not implemented" sentence passes
// the all-null case and reds the other two.
func TestIdentityVerdictIsMeasuredNotHardcoded(t *testing.T) {
	cases := []struct {
		name string
		revs []apiclient.Revision
		want string
	}{
		{
			name: "all unstamped",
			revs: []apiclient.Revision{rev("create", apiclient.Revision{}), rev("publish", apiclient.Revision{})},
			want: "UNMEASURED on 2 of 2",
		},
		{
			name: "mixed",
			revs: []apiclient.Revision{
				rev("create", apiclient.Revision{}),
				rev("publish", apiclient.Revision{ActorLabel: sp("agent:cli-r21d-w5")}),
			},
			want: "PARTIAL",
		},
		{
			name: "all stamped",
			revs: []apiclient.Revision{rev("create", apiclient.Revision{ActorKind: sp("agent")})},
			want: "every one of the 1 mutation(s) read was answered",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out, stdout, _ := historyTestWriter()
			renderTaskHistory(out, "task-x", historyReport{Read: true, Revisions: tc.revs})
			if !strings.Contains(stdout.String(), tc.want) {
				t.Fatalf("verdict did not contain %q:\n%s", tc.want, stdout.String())
			}
		})
	}
}

// TestHistoryNeverPresentsAClaimWorkerAsAttribution pins the refusal that makes
// the whole view honest: the command must state that it does not show
// content.claim.worker, and it must not read the row's claim at all — one
// source is asked, and it is the revision store.
func TestHistoryNeverPresentsAClaimWorkerAsAttribution(t *testing.T) {
	src := &fakeRevisionSource{revs: []apiclient.Revision{rev("create", apiclient.Revision{})}}
	rep := fetchHistory(src, "task-x", 50)
	if src.calls != 1 {
		t.Fatalf("the reader asked its source %d times, want exactly 1", src.calls)
	}
	out, stdout, _ := historyTestWriter()
	renderTaskHistory(out, "task-x", rep)
	body := stdout.String()
	if !strings.Contains(body, "content.claim.worker") || !strings.Contains(body, "self-report") {
		t.Fatalf("the output does not disclaim the client self-report:\n%s", body)
	}
}

// ===================== ARM 4: THE CLIENT STOPS DROPPING IT ===================

// TestRevisionDecodesAttributionThreeState is the arm for the apiclient change.
// It decodes the SERVER'S OWN SHAPE — the exact body
// BarkparkWeb.HistoryController.render_revision/1 emits, with null actor
// columns, as measured against the live ledger — and then the same body with
// the columns filled. Decode these into plain strings and the first case
// becomes indistinguishable from the second, which is the defect this field set
// removes.
func TestRevisionDecodesAttributionThreeState(t *testing.T) {
	nulls := `{"action":"publish","actor_id":null,"actor_kind":null,"actor_label":null,` +
		`"actor_user_id":null,"id":"605f5d14-2c9d-414d-82a1-b6ece332f876",` +
		`"rev":"0de410a6a9e5088d80cdb9b02942d89c","status":"published",` +
		`"timestamp":"2026-09-17T19:19:50.418045Z","title":"a row"}`

	var r apiclient.Revision
	if err := json.Unmarshal([]byte(nulls), &r); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if r.ActorKind != nil || r.ActorID != nil || r.ActorLabel != nil || r.ActorUserID != nil {
		t.Fatalf("a null actor column decoded to a non-nil pointer: %+v", r)
	}
	if r.Rev == nil || *r.Rev != "0de410a6a9e5088d80cdb9b02942d89c" {
		t.Fatalf("rev did not decode: %+v", r.Rev)
	}
	if got := classifyAttribution(r); got.State != attrNotStamped {
		t.Fatalf("the live production shape classified as %v, want NOT STAMPED", got.State)
	}

	filled := `{"action":"publish","actor_id":"tok_1","actor_kind":"agent","actor_label":"cli-r21d-w5",` +
		`"actor_user_id":"","id":"x","rev":"abc","status":"published",` +
		`"timestamp":"2026-09-17T19:19:50.418045Z","title":"a row"}`
	var f apiclient.Revision
	if err := json.Unmarshal([]byte(filled), &f); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if f.ActorUserID == nil || *f.ActorUserID != "" {
		t.Fatalf("a present empty column did not decode as present-and-empty: %+v", f.ActorUserID)
	}
	if got := classifyAttribution(f); got.State != attrStamped {
		t.Fatalf("a filled shape classified as %v, want STAMPED", got.State)
	}
}

// TestUnmeasuredRevColumnDoesNotRenderBlank — history written before the `rev`
// column existed is null, and a blank field there would read as a revision with
// an empty hash.
func TestUnmeasuredRevColumnDoesNotRenderBlank(t *testing.T) {
	if got := shortRev(nil); got != "(unmeasured)" {
		t.Fatalf("shortRev(nil) = %q", got)
	}
	if got := shortRev(sp("")); got == "(unmeasured)" {
		t.Fatalf("an answered-empty rev rendered as unmeasured")
	}
}

// TestTaskHistoryVerbIsRegistered — the verb must be discoverable, not an `if`
// in Execute. `bp task --help` and `bp capabilities` read this table.
func TestTaskHistoryVerbIsRegistered(t *testing.T) {
	for _, b := range nounBuiltins {
		if b.Noun == "task" && b.Verb == "history" {
			if b.Run == nil {
				t.Fatalf("task history is registered with no Run")
			}
			return
		}
	}
	t.Fatalf("task history is not in nounBuiltins — bp task --help would deny it exists")
}

// TestHistoryArgParsing — a second positional or an unknown flag is a usage
// error, never a silently-ignored argument that makes the command answer about
// a row the caller did not name.
func TestHistoryArgParsing(t *testing.T) {
	if _, _, err := parseHistoryArgs(nil); err == nil {
		t.Fatalf("no doc-id was accepted")
	}
	if _, _, err := parseHistoryArgs([]string{"a", "b"}); err == nil {
		t.Fatalf("two doc-ids were accepted")
	}
	if _, _, err := parseHistoryArgs([]string{"a", "--nope"}); err == nil {
		t.Fatalf("an unknown flag was accepted")
	}
	id, n, err := parseHistoryArgs([]string{"task-x", "--limit", "7"})
	if err != nil || id != "task-x" || n != 7 {
		t.Fatalf("parse = %q %d %v", id, n, err)
	}
}

// TestHistoryNamesItsSourceAndItsBlindSpot — the revision store is not the whole
// mutation set (2 revisions against 30 mutation_events on a real closed row,
// measured 2026-09-17). A timeline that does not name which store answered
// invites the reader to treat the events it cannot see as mutations that never
// happened.
//
// UPDATED for task-3b0be19ef722afef: the blind spot is now READ rather than
// merely disclosed, so the footer names BOTH stores and every line carries a
// [store] tag. The assertion moved with the behaviour; the property it guards
// — a reader can always tell which store answered — did not.
func TestHistoryNamesItsSourceAndItsBlindSpot(t *testing.T) {
	out, stdout, _ := historyTestWriter()
	renderTaskHistory(out, "task-x", historyReport{
		Read:      true,
		Revisions: []apiclient.Revision{rev("create", apiclient.Revision{})},
	})
	body := stdout.String()
	for _, want := range []string{"SOURCES:", "/v1/data/history", "/v1/tasks/events", "task.claimed", "[revision]"} {
		if !strings.Contains(body, want) {
			t.Fatalf("the output does not name %q:\n%s", want, body)
		}
	}
}
