package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// THE DEFECT THIS FILE CLOSES (task-3b9c9c99a0aa5a70).
//
// `bp task events` is a keyset replay over `mutation_events`, ordered id ASC
// (api/lib/barkpark/tasks/events.ex, `replay_since/3`: `order_by: [asc: e.id]`),
// and the server's own summary says so — "omit --since to replay from the
// start". Every word of that is TRUE. It still does not reach the reader who
// types `--limit 200` because they want to know what JUST happened: that
// command returns the TWO HUNDRED OLDEST EVENTS IN THE LEDGER, finds nothing
// recent, and says nothing about it.
//
// Measured on guerrilla 2026-09-15, against an event planted seconds earlier
// (event id 429605, `drafts.task-99cfea81cc4c40b1`):
//
//	bp task events --limit 200 -o json
//	  → 200 events, cursor 216, has_more true, first row dated 2026-07-01,
//	    ZERO rows for the planted id.
//
// A zero here and a genuine absence are byte-identical output, which is what
// makes this an instrument fault and not merely an API with an order. The
// generic truncation notice cannot catch it either: warnIfDefaultPageMayBeTruncated
// (run.go) returns immediately unless `cmd.Paginated`, and `task.events` is
// declared `paginated: false` — it pages by keyset, not by offset — so today
// nothing at all is printed.
//
// SERVER-OWNED HALF, stated plainly: the command SUMMARY and the flag summaries
// come from GET /v1/capabilities (api/lib/barkpark/plugins/tasks.ex) and cannot
// be edited from here. The help RENDER (usageCommand, usage.go) and the
// post-response advisories (run.go) are the CLI's, and they are the halves this
// file writes into — the same division list_envelope_help.go works within.
//
// WHAT WAS RULED ON RATHER THAN ASSUMED (the row's second criterion): does a
// newest-first / tail mode exist at all?
//
//   - NOT on this feed. `replay_since/3` hard-codes `order_by: [asc: e.id]` and
//     the controller action (`TasksController.events/2`) reads only `since`,
//     `limit`, `dataset`, `payload` and `doc_id` from params. There is no
//     `order`, `desc`, `reverse` or `tail` key, and an unknown flat param on
//     this route is neither honoured nor refused — it is ignored.
//   - YES, PARTLY, ELSEWHERE: `GET /v1/tasks/prime` carries `recent_events`,
//     built by `Barkpark.Tasks.Prime.recent_events/2` with
//     `order_by: [desc: e.inserted_at]` — a genuine newest-first tail. It is a
//     DIFFERENT PROJECTION, not this feed reversed, and the differences are
//     exactly the ones a reader gets wrong:
//     · at most 5 rows through `bp task prime`, whatever --limit says
//     (measured: --limit 1→1, 3→3, 7→5, 12→5, 200→5; the server trims the
//     slice for the view the CLI asks for, and `bp` declares no --view flag);
//     · `task.%` mutations ONLY — a plain `create`/`update`/`delete` on a task
//     document never appears there. The planted `create` above is present in
//     `task events` and ABSENT from `prime.recent_events`, measured;
//     · rows are `{event, doc_id, at}` — NO event `id`, so the tail cannot hand
//     you a cursor to resume `--since` from, and no `rev`, no `payload`.
//
// So the honest ruling is: a tail EXISTS and is named below, and it is not a
// substitute — a reverse/tail mode on this feed itself is worth adding
// server-side. That is a route, not this row's build; this file documents the
// ground as it stands and warns at the moment of the wrong read.

// taskEventsCommandID is the manifest id of the keyset replay feed.
const taskEventsCommandID = "task.events"

// taskEventsHelpLines is the block usageCommand renders under `bp task events
// --help`. It states the CONSEQUENCE of id-ASC, not just the ordering, and
// every recipe in it was run against a known-present planted event before it
// was written down (see the file comment).
func taskEventsHelpLines(cmd manifest.Command) []string {
	if cmd.ID != taskEventsCommandID {
		return nil
	}
	return []string{
		"",
		"WHICH END A BARE --limit READS: the OLDEST N, not the newest.",
		"  This stream is id-ASC and --since defaults to 0, so `bp task events --limit 200`",
		"  returns events 1..200 OF THE WHOLE LEDGER — the beginning of history. Looking there",
		"  for something that just happened returns ZERO, with no error and no warning, and a",
		"  zero here is indistinguishable from a genuine absence.",
		"  `has_more: true` in the envelope is the tell: the page was cut and the rest is NEWER.",
		"",
		"to actually see recent events:",
		"  ONE ROW      bp task events <doc_id> -o json",
		"               that row's whole history, oldest-first — the LAST element is the newest,",
		"               and its .id is a live cursor anchor. NOTE: a task created as a draft",
		"               events under `drafts.<id>`; the bare published id returns zero rows.",
		"  GLOBAL TAIL  bp task events --since <anchor-id> --limit 500 -o json",
		"               anchor off the .id above (or any id you have seen); page until",
		"               has_more is false — that, not an empty page, is the head of the stream.",
		"               `--since <an id past the end>` returns an empty page whose cursor is",
		"               your own --since: it looks exactly like being caught up.",
		"  NEWEST-FIRST bp task prime -o json | jq '.recent_events'",
		"               a real desc-ordered tail, but a DIFFERENT projection: at most 5 rows,",
		"               `task.*` mutations only (a plain create/update on a task is not there),",
		"               and no event id — so it can never hand you a --since cursor.",
		"  This feed itself has NO --order/--desc/--tail: the server sorts id ASC with no",
		"  reverse mode (api Barkpark.Tasks.Events.replay_since/3).",
	}
}

// taskEventsWindowAdvisory is the run-time half — the one that reaches the
// reader who never typed `--help`. It fires only on `task.events`, only on a
// 2xx, only when the caller left `--since` at its default (so the page really
// did start at the beginning of the backlog), and only when the server says
// `has_more` (so the page really was cut and the rest really is newer).
//
// A reader who omitted --since AND got a complete stream has been told the
// truth by the rows themselves and hears nothing from here.
//
// Returns "" when there is nothing honest to say. Advisory only: stderr, never
// stdout, never the exit code — `-o json` stays byte-identical.
func taskEventsWindowAdvisory(cmd manifest.Command, requestURL string, status int, respBody []byte) string {
	if cmd.ID != taskEventsCommandID || status < 200 || status >= 300 {
		return ""
	}
	if taskEventsSinceGiven(requestURL) {
		return ""
	}
	var body struct {
		Events  []json.RawMessage `json:"events"`
		Cursor  int64             `json:"cursor"`
		HasMore bool              `json:"has_more"`
	}
	if err := json.Unmarshal(respBody, &body); err != nil {
		return ""
	}
	if !body.HasMore {
		return ""
	}
	// The remedy names the cursor the caller was just handed, because the next
	// command they should run is that number plugged into --since — and because
	// a cursor of 216 sitting under a request for 200 rows is itself the proof
	// that this page is the START of the ledger, not the end.
	return fmt.Sprintf(
		"you read the OLDEST %d events in the backlog, not the newest — this stream is id-ASC and "+
			"--since was omitted (cursor=%d, has_more=true). ANYTHING RECENT IS NOT IN THIS PAGE, and zero "+
			"hits here cannot be read as absent. Page forward with --since %d, or read one row's history "+
			"with `bp task events <doc_id>`, or the newest-first tail with "+
			"`bp task prime -o json | jq '.recent_events'` (at most 5 rows, task.* mutations only, no event ids).",
		len(body.Events), body.Cursor, body.Cursor)
}

// taskEventsSinceGiven reports whether the request actually carried a resume
// cursor. `--since 0` is the DEFAULT and means "from the start", so it counts
// as not given: the advisory is about where the window sits, not about which
// flags were typed, and a caller who spelled the default out loud is in exactly
// the same place as one who omitted it.
func taskEventsSinceGiven(requestURL string) bool {
	q := requestURL
	if i := strings.Index(q, "?"); i >= 0 {
		q = q[i+1:]
	} else {
		return false
	}
	values, err := url.ParseQuery(q)
	if err != nil {
		// An unparseable query is not evidence that --since was absent, and the
		// advisory must never accuse on a guess. Stay silent.
		return true
	}
	raw := strings.TrimSpace(values.Get("since"))
	if raw == "" {
		return false
	}
	return raw != "0"
}
