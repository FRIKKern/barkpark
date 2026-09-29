package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// tasks_history_events.go — the SECOND store `bp task history` reads
// (task-3b0be19ef722afef).
//
// ========================== THE DEFECT THIS FILE CLOSES ======================
//
// `bp task history` read ONLY the revision store, and reported its verdict as
// if that store were the whole ledger. But the task verbs — claim, pulse,
// close, release, stamp — write NO revision at all: they mutate the claim map
// and emit a row on `mutation_events`. So the one surface that renders a
// verdict about WHO mutated a task row was structurally blind to every task
// mutation, and printed the server's RECORDED answer as "the store recorded no
// actor".
//
// MEASURED on guerrilla/production 2026-09-20, on scratch row
// task-bfb81eb03bec8847, claimed and closed at 10:06:01Z:
//
//	bp task history task-bfb81eb03bec8847
//	  -> agent_identity_verdict UNMEASURED, count 4,
//	     every revision attribution_state NOT STAMPED
//
//	bp task events task-bfb81eb03bec8847 --payload   # SAME row, SAME mutation
//	  -> task.claimed payload.caller
//	       {"id":"e5ce2b91-…","kind":"api_token","session":"s_a27da76950c664eb"}
//	     task.closed   payload.caller  (identical block)
//
// UNMEASURED there was not merely unhelpful. The verb's own help promises the
// word means "the store recorded no actor, which is NOT 'nobody'", and that
// sentence was FALSE whenever the events feed held a caller.
//
// ===================== WHAT THIS FILE IS NOT ALLOWED TO DO ===================
//
// The remedy is to READ THE OTHER STORE, not to soften the word. Two failure
// directions are named in the row and both are forbidden here:
//
//   - Renaming UNMEASURED, or defaulting the verdict to ANSWERED. A verdict
//     that can only ever say ANSWERED is a verdict about nothing. A mutation
//     whose event carries no caller block STAYS NOT STAMPED, and a row mutated
//     before the server started stamping stays UNMEASURED — it does not become
//     ANSWERED-EMPTY, because nothing answered.
//   - Swallowing a failed events read. The events feed is now load-bearing for
//     the verdict, so a read that FAILS is a MEASURED FAILURE of the command:
//     non-zero exit, named store, no timeline. An events fault rendered as
//     "no caller found" would manufacture exactly the absence this row exists
//     to delete.
//
// The same three-state law that governs the revision columns governs the
// caller block, for the same reason: no caller key at all is UNMEASURED, a
// caller block whose fields are all empty is an ANSWER of nothing, a caller
// block with a value is identity.

// taskEventsPath is the flat replay route. `payload=true` is what carries the
// caller block; without it the server returns {at, doc_id, event, id, rev} and
// this whole file measures nothing.
const taskEventsPath = "/v1/tasks/events"

// taskEvent is one row of `mutation_events`, decoded down to the two things
// this reader needs: WHEN/WHAT it was, and the caller block the server stamped
// on it.
type taskEvent struct {
	ID    int64
	At    time.Time
	Event string
	Rev   *string
	// Caller is nil when the payload carried NO caller key. That is
	// UNMEASURED, and it is distinct from a caller block whose fields are
	// present and empty.
	Caller *eventCaller
}

// eventCaller is the server-stamped actor block on a task mutation. Pointers,
// for the same reason apiclient.Revision uses them: a key the server never
// wrote (nil) and a key it wrote empty ("") are DIFFERENT answers, and
// collapsing them is the defect.
type eventCaller struct {
	Kind    *string
	ID      *string
	Session *string
}

// classifyEventAttribution applies the three-state law to one event's caller
// block. Deleting the nil/empty split here — or returning attrStamped
// unconditionally — must red TestEventAttributionSplitsTheTwoAbsences and
// TestVerdictStaysUnmeasuredWhenNoEventCarriesACaller.
func classifyEventAttribution(ev taskEvent) attribution {
	var a attribution
	if ev.Caller == nil {
		// No caller key in the payload. The server never stamped this
		// mutation. UNMEASURED — NOT "nobody".
		a.State = attrNotStamped
		return a
	}
	cols := []struct {
		name string
		val  *string
	}{
		{"caller_kind", ev.Caller.Kind},
		{"caller_id", ev.Caller.ID},
		{"caller_session", ev.Caller.Session},
	}
	anyPresent := false
	anyValued := false
	for _, c := range cols {
		if c.val == nil {
			continue
		}
		anyPresent = true
		if *c.val != "" {
			anyValued = true
		}
		a.Fields = append(a.Fields, fmt.Sprintf("%s=%q", c.name, *c.val))
	}
	switch {
	case anyValued:
		a.State = attrStamped
	case anyPresent:
		a.State = attrAnsweredEmpty
	default:
		// A caller key present but EMPTY as an object: the server answered
		// with an object and put nothing in it. Still an answer.
		a.State = attrAnsweredEmpty
	}
	return a
}

// taskEventSource is the events feed, injected for the same reason
// revisionSource is: neither a server that stamps no caller nor a read that
// fails can be asked of the real network inside a unit test, and without
// injection the failure arm has nothing that reds when it is deleted.
type taskEventSource interface {
	TaskEvents(docID string, limit int) (events []taskEvent, hasMore bool, err error)
}

// eventsOutcome is one events read. NIL (as *eventsOutcome on a report) means
// NO events read was part of that report — itself an UNMEASURED, and the only
// shape in which the command's exit code may ignore this store.
type eventsOutcome struct {
	Read    bool
	Fault   string
	Events  []taskEvent
	HasMore bool
	// Probed is the doc_id the answering read actually used. A task created
	// as a draft events under `drafts.<id>`, and naming the id that answered
	// keeps a reader from reading a bare-id zero as an absence.
	Probed string
}

// httpTaskEventSource reads the live feed over the CLI's own transport.
type httpTaskEventSource struct {
	server  string
	token   string
	dataset string
}

func (s httpTaskEventSource) TaskEvents(docID string, limit int) ([]taskEvent, bool, error) {
	evs, more, err := s.fetchOne(docID, limit)
	if err != nil {
		return nil, false, err
	}
	// THE DRAFT-ID TRAP, handled rather than inherited. `bp task events
	// --help` states it: a task created as a draft events under
	// `drafts.<id>`, and the bare published id returns ZERO rows. A zero here
	// would land in the verdict as "no mutation carried a caller" — an
	// absence manufactured by asking the wrong key. Ask the other key before
	// concluding anything.
	if len(evs) == 0 && !strings.HasPrefix(docID, "drafts.") {
		alt := "drafts." + docID
		altEvs, altMore, altErr := s.fetchOne(alt, limit)
		if altErr == nil && len(altEvs) > 0 {
			return altEvs, altMore, nil
		}
	}
	return evs, more, nil
}

func (s httpTaskEventSource) fetchOne(docID string, limit int) ([]taskEvent, bool, error) {
	q := url.Values{}
	q.Set("doc_id", docID)
	q.Set("payload", "true")
	if limit > 0 {
		q.Set("limit", strconv.Itoa(limit))
	}
	if s.dataset != "" {
		q.Set("dataset", s.dataset)
	}
	endpoint := strings.TrimRight(s.server, "/") + taskEventsPath + "?" + q.Encode()

	headers := map[string]string{"Accept": "application/json"}
	if s.token != "" {
		headers["Authorization"] = "Bearer " + s.token
	}
	status, body, err := doRequest("GET", endpoint, headers, nil)
	if err != nil {
		return nil, false, fmt.Errorf("task events transport: %w", err)
	}
	if status < 200 || status >= 300 {
		snippet := string(body)
		if len(snippet) > 512 {
			snippet = snippet[:512]
		}
		return nil, false, fmt.Errorf("task events error %d: %s", status, snippet)
	}
	return decodeTaskEvents(body)
}

// decodeTaskEvents turns one envelope into typed events. A body that does not
// decode is a FAULT, never an empty feed — a parse failure rendered as zero
// events is the same manufactured absence as a swallowed 500.
func decodeTaskEvents(body []byte) ([]taskEvent, bool, error) {
	var env struct {
		Events []struct {
			ID      int64           `json:"id"`
			At      time.Time       `json:"at"`
			Event   string          `json:"event"`
			Rev     *string         `json:"rev"`
			Payload json.RawMessage `json:"payload"`
		} `json:"events"`
		HasMore bool `json:"has_more"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, false, fmt.Errorf("parse task events response: %w", err)
	}
	out := make([]taskEvent, 0, len(env.Events))
	for _, e := range env.Events {
		ev := taskEvent{ID: e.ID, At: e.At, Event: e.Event, Rev: e.Rev}
		ev.Caller = decodeEventCaller(e.Payload)
		out = append(out, ev)
	}
	return out, env.HasMore, nil
}

// decodeEventCaller returns nil when the payload carried no `caller` key at
// all — the UNMEASURED case — and a non-nil block whenever the key exists,
// however empty its fields are.
func decodeEventCaller(payload json.RawMessage) *eventCaller {
	if len(payload) == 0 {
		return nil
	}
	var p struct {
		Caller json.RawMessage `json:"caller"`
	}
	if err := json.Unmarshal(payload, &p); err != nil {
		return nil
	}
	if len(p.Caller) == 0 || string(p.Caller) == "null" {
		return nil
	}
	var c struct {
		Kind    *string `json:"kind"`
		ID      *string `json:"id"`
		Session *string `json:"session"`
	}
	if err := json.Unmarshal(p.Caller, &c); err != nil {
		return nil
	}
	return &eventCaller{Kind: c.Kind, ID: c.ID, Session: c.Session}
}

// fetchTaskEvents asks the events feed ONCE and reports what happened. A
// failure NEVER yields an event list: Read stays false and Events stays nil,
// so no renderer downstream can mistake an unread feed for an empty one.
func fetchTaskEvents(src taskEventSource, docID string, limit int) *eventsOutcome {
	evs, more, err := src.TaskEvents(docID, limit)
	if err != nil {
		return &eventsOutcome{Fault: err.Error(), Probed: docID}
	}
	return &eventsOutcome{Read: true, Events: evs, HasMore: more, Probed: docID}
}
