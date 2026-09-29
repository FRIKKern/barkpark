package cli

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// tasks_history_events_test.go — the arms for task-3b0be19ef722afef.
//
// The row's first two criteria are ANTI-VACUITY criteria, and they are the
// point: a verdict that can only ever say ANSWERED is a verdict about nothing,
// and a FAILED events read that becomes a confident UNMEASURED is the original
// defect wearing the fix's name. Each test below names the mutation that reds
// it.

// fakeTaskEventSource hands the reader exactly the events a test names, or the
// error it names. Injection is the point for the same reason it is on the
// revision side: neither "the server stamped no caller" nor "the feed did not
// answer" can be asked of the real network inside a unit test.
type fakeTaskEventSource struct {
	events  []taskEvent
	hasMore bool
	err     error
	calls   int
}

func (f *fakeTaskEventSource) TaskEvents(docID string, limit int) ([]taskEvent, bool, error) {
	f.calls++
	if f.err != nil {
		return nil, false, f.err
	}
	return f.events, f.hasMore, nil
}

func evAt(s string) time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		panic(err)
	}
	return t
}

// liveClaimedEvent is the EXACT shape measured on guerrilla/production
// 2026-09-20 for scratch row task-bfb81eb03bec8847 (event id 462527):
//
//	task.claimed payload.caller
//	  {"id":"e5ce2b91-…","kind":"api_token","session":"s_a27da76950c664eb"}
//
// A fixture invented rather than measured is how a selftest ends up encoding a
// shape the system never emits.
func liveClaimedEvent() taskEvent {
	return taskEvent{
		ID:    462527,
		At:    evAt("2026-09-20T10:06:01.171934Z"),
		Event: "task.claimed",
		Rev:   sp("c4d57bb7071c66b369cffc8d86785440"),
		Caller: &eventCaller{
			Kind:    sp("api_token"),
			ID:      sp("e5ce2b91-e38d-426e-ae68-5006dc414b97"),
			Session: sp("s_a27da76950c664eb"),
		},
	}
}

// ================== ARM 1: THE DEFECT, AS A FAILING-BEFORE TEST ==============

// TestEventsCallerLiftsTheVerdictOffUnmeasured is criterion 1. It replays the
// live production shape: four revisions with every actor column null (which is
// ALL the old reader could see, and why it said UNMEASURED) plus the
// task.claimed event the server DID stamp.
//
// REDS IF: buildTimeline stops reading rep.Events, or drops an event that has
// no matching revision, or classifyEventAttribution stops looking at the
// caller block. Any of those returns the verdict to UNMEASURED — the defect.
func TestEventsCallerLiftsTheVerdictOffUnmeasured(t *testing.T) {
	rep := historyReport{
		Read: true,
		Revisions: []apiclient.Revision{
			{Action: "publish", Timestamp: evAt("2026-09-20T10:05:45.195792Z"), Rev: sp("f41ee0597c67bef3255971316b284809")},
			{Action: "create", Timestamp: evAt("2026-09-20T10:05:45.022035Z"), Rev: sp("13f9e11385c1b0c5ca9fc652606d10cc")},
		},
		Events: &eventsOutcome{Read: true, Events: []taskEvent{liveClaimedEvent()}},
	}

	entries := buildTimeline(rep.Revisions, rep.Events)
	if len(entries) != 3 {
		t.Fatalf("the claim event was dropped: want 3 mutations, got %d", len(entries))
	}
	notStamped := 0
	for _, e := range entries {
		if e.Attr.State == attrNotStamped {
			notStamped++
		}
	}
	if got := identityVerdict(len(entries), notStamped); got != "PARTIAL" {
		t.Fatalf("verdict = %q, want PARTIAL (2 null revisions + 1 stamped claim)", got)
	}

	out, stdout, _ := historyTestWriter()
	if code := renderTaskHistory(out, "task-bfb81eb03bec8847", rep); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	body := stdout.String()
	for _, want := range []string{
		"task.claimed",
		"[events]",
		`caller_kind="api_token"`,
		`caller_session="s_a27da76950c664eb"`,
		"AGENT IDENTITY: PARTIAL",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("output does not carry %q:\n%s", want, body)
		}
	}
}

// TestEventUpgradesAMatchingRevisionRatherThanDuplicatingIt — a revision and an
// event that share a `rev` are ONE mutation seen twice. Counting it twice would
// inflate the denominator of every verdict this command prints.
//
// REDS IF: the rev-keyed merge in buildTimeline is removed (2 entries), or the
// upgrade is removed (the entry stays NOT STAMPED).
func TestEventUpgradesAMatchingRevisionRatherThanDuplicatingIt(t *testing.T) {
	shared := "c4d57bb7071c66b369cffc8d86785440"
	revs := []apiclient.Revision{{Action: "update", Timestamp: evAt("2026-09-20T10:06:01Z"), Rev: sp(shared)}}
	ev := &eventsOutcome{Read: true, Events: []taskEvent{liveClaimedEvent()}}

	entries := buildTimeline(revs, ev)
	if len(entries) != 1 {
		t.Fatalf("shared-rev mutation counted %d times, want 1", len(entries))
	}
	if entries[0].Attr.State != attrStamped {
		t.Fatalf("the matching event did not upgrade the null revision: state = %v", entries[0].Attr.State)
	}
	if entries[0].Source != "revision+events" {
		t.Fatalf("source = %q, want revision+events", entries[0].Source)
	}
}

// ======= ARM 2: THE VERDICT MUST STILL BE ABLE TO SAY UNMEASURED ============

// TestVerdictStaysUnmeasuredWhenNoEventCarriesACaller is criterion 2, and it is
// the anti-vacuity arm. It is the CONTROL for the test above: same code path,
// same stores read, same event kinds — and the events carry NO caller block,
// which is exactly the shape of every task row mutated before the server began
// stamping one.
//
// REDS IF: the verdict is defaulted to ANSWERED, or classifyEventAttribution
// returns anything but attrNotStamped for a missing caller key, or a missing
// caller is promoted to ANSWERED-EMPTY. Without this arm, a fix that hardcoded
// "PARTIAL" would pass the test above.
func TestVerdictStaysUnmeasuredWhenNoEventCarriesACaller(t *testing.T) {
	// A pre-stamping row: task verbs fired, the server recorded no caller.
	pre := []taskEvent{
		{ID: 1, At: evAt("2026-08-01T10:00:00Z"), Event: "task.claimed", Rev: sp("aaa")},
		{ID: 2, At: evAt("2026-08-01T10:30:00Z"), Event: "task.closed", Rev: sp("bbb")},
	}
	rep := historyReport{
		Read:      true,
		Revisions: []apiclient.Revision{{Action: "create", Timestamp: evAt("2026-08-01T09:00:00Z"), Rev: sp("ccc")}},
		Events:    &eventsOutcome{Read: true, Events: pre},
	}

	entries := buildTimeline(rep.Revisions, rep.Events)
	if len(entries) != 3 {
		t.Fatalf("want 3 mutations, got %d", len(entries))
	}
	notStamped := 0
	for _, e := range entries {
		if e.Attr.State != attrNotStamped {
			t.Fatalf("a caller-less %s event read as %v — the store answered nothing and must stay UNMEASURED",
				e.What, e.Attr.State)
		}
		notStamped++
	}
	if got := identityVerdict(len(entries), notStamped); got != "UNMEASURED" {
		t.Fatalf("verdict = %q, want UNMEASURED on a row no store stamped", got)
	}

	out, stdout, _ := historyTestWriter()
	renderTaskHistory(out, "task-old", rep)
	body := stdout.String()
	if !strings.Contains(body, "AGENT IDENTITY: UNMEASURED on 3 of 3") {
		t.Fatalf("footer softened the absence:\n%s", body)
	}
	if strings.Contains(body, "ANSWERED-EMPTY") {
		t.Fatalf("a caller key that was never written was rendered as an ANSWER:\n%s", body)
	}
}

// TestEventAttributionSplitsTheTwoAbsences pins the three-state law on the
// caller block itself — the same split classifyAttribution enforces on the
// revision columns, and for the same reason.
//
// REDS IF: the nil-caller and empty-caller cases are collapsed in either
// direction.
func TestEventAttributionSplitsTheTwoAbsences(t *testing.T) {
	cases := []struct {
		name string
		in   taskEvent
		want attributionState
	}{
		{"no caller key at all is NOT STAMPED", taskEvent{Event: "task.claimed"}, attrNotStamped},
		{"a caller block with an empty field is ANSWERED-EMPTY",
			taskEvent{Caller: &eventCaller{Kind: sp("")}}, attrAnsweredEmpty},
		{"a caller block with no fields at all is ANSWERED-EMPTY",
			taskEvent{Caller: &eventCaller{}}, attrAnsweredEmpty},
		{"a valued caller is STAMPED", liveClaimedEvent(), attrStamped},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyEventAttribution(tc.in).State; got != tc.want {
				t.Fatalf("state = %v, want %v", got, tc.want)
			}
		})
	}
}

// TestDecodeEventCallerKeepsNullApartFromEmpty runs the split through the REAL
// decoder rather than a hand-built struct, because the collapse this file
// guards against is most naturally introduced at the JSON boundary (decoding
// caller into a value type would make an absent key indistinguishable from an
// empty one).
func TestDecodeEventCallerKeepsNullApartFromEmpty(t *testing.T) {
	if c := decodeEventCaller(json.RawMessage(`{"actor":{"worker":"lead-cli"}}`)); c != nil {
		t.Fatalf("a payload with NO caller key decoded to a caller block: %+v", c)
	}
	if c := decodeEventCaller(json.RawMessage(`{"caller":null}`)); c != nil {
		t.Fatalf("an explicitly null caller decoded to a block: %+v", c)
	}
	c := decodeEventCaller(json.RawMessage(`{"caller":{"kind":""}}`))
	if c == nil || c.Kind == nil || *c.Kind != "" {
		t.Fatalf("a present-but-empty caller field was lost: %+v", c)
	}
	// The live shape, verbatim from guerrilla 2026-09-20 event 462527.
	c = decodeEventCaller(json.RawMessage(
		`{"actor":{"epoch":1,"worker":"lead-cli"},"caller":{"id":"e5ce2b91-e38d-426e-ae68-5006dc414b97","kind":"api_token","session":"s_a27da76950c664eb"},"session":"s_a27da76950c664eb"}`))
	if c == nil || c.Kind == nil || *c.Kind != "api_token" || c.Session == nil || *c.Session != "s_a27da76950c664eb" {
		t.Fatalf("the live caller block did not decode: %+v", c)
	}
}

// ============ ARM 3: A FAILED EVENTS READ IS NOT A CONFIDENT ZERO ===========

// TestFailedEventsReadExitsNonZeroAndSaysSo is criterion 3. The events feed is
// now load-bearing for the verdict, so its fault must fail the COMMAND.
//
// REDS IF: the !rep.Events.Read arm in renderTaskHistory is removed or
// downgraded to a warning. That mutation makes a 500 on the events feed
// byte-identical to a row whose mutations nobody stamped — the exact absence
// this row exists to delete, reintroduced one layer up.
func TestFailedEventsReadExitsNonZeroAndSaysSo(t *testing.T) {
	rep := historyReport{
		Read:      true, // the revision store DID answer
		Revisions: []apiclient.Revision{rev("create", apiclient.Revision{})},
		Events:    &eventsOutcome{Fault: "task events error 500: boom"},
	}
	out, stdout, stderr := historyTestWriter()
	code := renderTaskHistory(out, "task-x", rep)
	if code == exitOK {
		t.Fatalf("a failed events read exited 0")
	}
	if strings.Contains(stdout.String(), "AGENT IDENTITY") {
		t.Fatalf("a verdict was rendered over a feed that did not answer:\n%s", stdout.String())
	}
	body := stderr.String()
	for _, want := range []string{"MEASURED FAILURE", "mutation_events", "task events error 500: boom"} {
		if !strings.Contains(body, want) {
			t.Fatalf("stderr does not name %q:\n%s", want, body)
		}
	}
}

// TestFetchTaskEventsNeverYieldsEventsOnAFault — the fault must not be able to
// carry a list. A source that returned partial rows alongside an error, merged
// into the timeline, would let a half-read feed pose as a whole one.
func TestFetchTaskEventsNeverYieldsEventsOnAFault(t *testing.T) {
	got := fetchTaskEvents(&fakeTaskEventSource{err: errors.New("dial tcp: refused")}, "task-x", 50)
	if got.Read {
		t.Fatalf("a faulted read reported Read=true")
	}
	if len(got.Events) != 0 {
		t.Fatalf("a faulted read carried %d events", len(got.Events))
	}
	if !strings.Contains(got.Fault, "refused") {
		t.Fatalf("fault = %q", got.Fault)
	}
}

// TestDecodeTaskEventsFaultsOnGarbageRatherThanReturningZero — a body that does
// not decode is a fault. Returning (nil, false, nil) here would route an
// unparseable response straight into "no mutation carried a caller".
func TestDecodeTaskEventsFaultsOnGarbageRatherThanReturningZero(t *testing.T) {
	if _, _, err := decodeTaskEvents([]byte("<html>502 Bad Gateway</html>")); err == nil {
		t.Fatalf("an undecodable body was reported as an empty feed")
	}
}

// TestFetchHistoryAndEventsAlwaysAttemptsTheEventsFeed — the wiring guard. A
// nil Events outcome is the ONE shape whose exit code ignores the second store,
// so the production path must never produce one.
//
// REDS IF: fetchHistoryAndEvents stops calling the events source, which is
// precisely how this fix would silently revert.
func TestFetchHistoryAndEventsAlwaysAttemptsTheEventsFeed(t *testing.T) {
	ev := &fakeTaskEventSource{}
	rep := fetchHistoryAndEvents(&fakeRevisionSource{}, ev, "task-x", 50)
	if ev.calls != 1 {
		t.Fatalf("the events feed was asked %d times, want 1", ev.calls)
	}
	if rep.Events == nil {
		t.Fatalf("the report carried no events outcome — the second store would be silently skipped")
	}

	// And it must still attempt the events feed when the revision store
	// FAILED, so the command can name both faults rather than only the first.
	ev2 := &fakeTaskEventSource{}
	rep2 := fetchHistoryAndEvents(&fakeRevisionSource{err: errors.New("nope")}, ev2, "task-x", 50)
	if rep2.Events == nil || ev2.calls != 1 {
		t.Fatalf("the events feed was skipped after a revision fault")
	}
}

// TestMachineOutputStatesWhetherTheEventsFeedWasRead — a JSON consumer that
// cannot tell "the feed said no caller" from "the feed was never asked" is back
// at the defect, one layer up.
func TestMachineOutputStatesWhetherTheEventsFeedWasRead(t *testing.T) {
	out, stdout, _ := newTestWriter()
	out.output = "json"
	renderTaskHistory(out, "task-x", historyReport{
		Read:      true,
		Revisions: []apiclient.Revision{{Action: "publish", Timestamp: evAt("2026-09-20T10:05:45Z"), Rev: sp("f41ee059")}},
		Events:    &eventsOutcome{Read: true, Events: []taskEvent{liveClaimedEvent()}},
	})
	var got map[string]any
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("machine output is not JSON: %v\n%s", err, stdout.String())
	}
	if got["events_read"] != true {
		t.Fatalf("events_read = %v, want true", got["events_read"])
	}
	if got["agent_identity_verdict"] != "PARTIAL" {
		t.Fatalf("verdict = %v, want PARTIAL", got["agent_identity_verdict"])
	}
	if got["count"] != float64(2) {
		t.Fatalf("count = %v, want 2", got["count"])
	}
}
