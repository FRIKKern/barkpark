package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp task events --limit N` returns the N OLDEST events (task-3b9c9c99a0aa5a70).
//
// The fixtures below are not invented shapes: they are the envelopes measured
// against guerrilla on 2026-09-15, around an event planted seconds before the
// read (`drafts.task-99cfea81cc4c40b1`, event id 429605).

func eventsWindowCmd() manifest.Command {
	return manifest.Command{
		ID:    taskEventsCommandID,
		Noun:  "task",
		Verb:  "events",
		HTTP:  manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/events"},
		Args:  []manifest.Arg{{Name: "doc_id", Required: false, Type: "string"}},
		Flags: []manifest.Flag{{Name: "since", Type: "int"}, {Name: "limit", Type: "int"}},
		// The manifest declares this feed NON-paginated — it pages by keyset,
		// not by offset. That is exactly why the generic truncation notice
		// cannot reach it; pinned by TestGenericTruncationNoticeCannotCoverEvents.
		Paginated: false,
	}
}

// bodyOldestPage is the MEASURED envelope of `bp task events --limit 200`:
// 200 rows, cursor 216, has_more true — a cursor of 216 under a request for
// 200 rows is itself the proof that the page came from the START of the ledger.
func bodyOldestPage(n int, cursor int64, hasMore bool) []byte {
	rows := make([]map[string]any, 0, n)
	for i := 0; i < n; i++ {
		rows = append(rows, map[string]any{
			"id":     16 + i,
			"event":  "create",
			"doc_id": fmt.Sprintf("drafts.lvw-%d", i),
			"at":     "2026-07-01T19:20:37.580519Z",
		})
	}
	b, _ := json.Marshal(map[string]any{
		"ok": true, "events": rows, "cursor": cursor, "has_more": hasMore,
	})
	return b
}

func TestEventsWindowAdvisoryFiresOnABareLimit(t *testing.T) {
	note := taskEventsWindowAdvisory(eventsWindowCmd(),
		"https://guerrilla.barkpark.cloud/v1/tasks/events?limit=200",
		200, bodyOldestPage(200, 216, true))
	if note == "" {
		t.Fatal("no advisory on the exact page that fooled a lane: 200 rows, cursor 216, has_more true")
	}
	// The ORDERING was already documented and did not reach anyone. What has to
	// be said is the CONSEQUENCE — which end, and that a zero is not an absence.
	for _, want := range []string{"OLDEST", "NOT IN THIS PAGE", "cannot be read as absent", "--since 216"} {
		if !strings.Contains(note, want) {
			t.Fatalf("advisory does not say %q: %s", want, note)
		}
	}
}

// The advisory must be able to STAY SILENT, or it is not an instrument, it is a
// banner. These are the three shapes on which the caller has not been fooled.
func TestEventsWindowAdvisorySilentWhenNotFooled(t *testing.T) {
	cmd := eventsWindowCmd()
	cases := []struct {
		name, url string
		status    int
		body      []byte
	}{
		// The whole stream came back: the rows themselves told the truth.
		{"complete stream", "/v1/tasks/events?limit=500", 200, bodyOldestPage(3, 429606, false)},
		// A resume cursor was given: this page is where the caller aimed it.
		{"since given", "/v1/tasks/events?since=429500&limit=200", 200, bodyOldestPage(200, 429700, true)},
		// A per-row read that is genuinely truncated still gets the advisory, so
		// the silent case here is the per-row read that is NOT truncated.
		{"per-row complete", "/v1/tasks/events?doc_id=drafts.task-99cfea81cc4c40b1", 200,
			bodyOldestPage(1, 429605, false)},
		{"refusal", "/v1/tasks/events?limit=200", 400, bodyOldestPage(0, 0, true)},
		{"unparseable body", "/v1/tasks/events?limit=200", 200, []byte("<html>")},
	}
	for _, c := range cases {
		if note := taskEventsWindowAdvisory(cmd, c.url, c.status, c.body); note != "" {
			t.Fatalf("%s: advisory fired when it had nothing honest to say: %s", c.name, note)
		}
	}
}

// `--since 0` IS the default and means "from the start". A caller who spells it
// out loud is in exactly the same place as one who omitted it, so the advisory
// keys on WHERE THE WINDOW SITS, not on which flags were typed.
func TestEventsWindowAdvisoryTreatsSinceZeroAsAbsent(t *testing.T) {
	note := taskEventsWindowAdvisory(eventsWindowCmd(),
		"/v1/tasks/events?since=0&limit=200", 200, bodyOldestPage(200, 216, true))
	if note == "" {
		t.Fatal("--since 0 is the default (replay from the start) and must not silence the advisory")
	}
}

// Scoping: no other command may acquire this line.
func TestEventsWindowAdvisoryIsScopedToTheEventsFeed(t *testing.T) {
	other := eventsWindowCmd()
	other.ID = "task.ls"
	if note := taskEventsWindowAdvisory(other, "/v1/tasks?limit=200", 200, bodyOldestPage(200, 216, true)); note != "" {
		t.Fatalf("advisory leaked onto %s: %s", other.ID, note)
	}
	if lines := taskEventsHelpLines(other); len(lines) != 0 {
		t.Fatalf("help block leaked onto %s: %v", other.ID, lines)
	}
}

// THE SUBJECT OF THE HELP CRITERION. Today's help is accurate and still fools
// people, so this arm asserts the sentences that do the work: which end, and
// the three recipes that actually surface recent events. Each recipe was run
// against a KNOWN-PRESENT planted event before it was written down; a recipe
// nobody has run against something they know is there cannot tell them whether
// it finds things.
func TestEventsHelpNamesWhichEndAndTheRecipes(t *testing.T) {
	got := strings.Join(taskEventsHelpLines(eventsWindowCmd()), "\n")
	if got == "" {
		t.Fatal("no help block for task.events")
	}
	for _, want := range []string{
		"the OLDEST N, not the newest",
		"indistinguishable from a genuine absence",
		"has_more: true",
		"bp task events <doc_id>",
		"drafts.<id>",
		"--since <anchor-id>",
		"bp task prime -o json | jq '.recent_events'",
		"at most 5 rows",
		"NO --order/--desc/--tail",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("help does not say %q:\n%s", want, got)
		}
	}
}

// WHY A NEW ADVISORY AT ALL — the negative half, and the arm that fails if
// someone later decides the generic notice already covers this. It does not:
// warnIfDefaultPageMayBeTruncated returns on its first line unless
// cmd.Paginated, and `task.events` is declared paginated:false in the server
// manifest (it pages by keyset). If the manifest ever flips, this test reds and
// the overlap gets decided on purpose instead of by accident.
func TestGenericTruncationNoticeCannotCoverEvents(t *testing.T) {
	cmd := eventsWindowCmd()
	if cmd.Paginated {
		t.Fatal("task.events is now paginated — re-decide the overlap with warnIfDefaultPageMayBeTruncated")
	}
	out, _, stderr := newTestWriter()
	g := globals{limit: 200, limitSet: true}
	warnIfDefaultPageMayBeTruncated(out, g, cmd, bodyOldestPage(200, 216, true))
	if stderr.String() != "" {
		t.Fatalf("the generic notice DOES cover this after all: %q", stderr.String())
	}
}
