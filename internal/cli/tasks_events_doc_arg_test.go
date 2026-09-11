package cli

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp task events <id>` — the per-row audit view (tlv-bl-events-actor-attribution).
//
// The server half of that row adds an OPTIONAL positional `doc_id` to the
// `task.events` manifest spec, whose `path_template` (`/v1/tasks/events`) has
// no `:doc_id` placeholder. That combination is what makes the CLI send
// `?doc_id=<id>` with no Go change — but "with no Go change" is a claim about
// THIS package's generic binder, so it is pinned here rather than assumed.
//
// Before the manifest declared the arg, `args: []` made every positional an
// error: "too many arguments for task events (expected 0)". A done-set audit
// (2026-08-18) hit exactly that and had to replay the whole global backlog to
// read one row's history.
func eventsCmd() manifest.Command {
	return manifest.Command{
		Noun: "task",
		Verb: "events",
		HTTP: manifest.HTTP{Method: "GET", PathTemplate: "/v1/tasks/events"},
		Args: []manifest.Arg{{Name: "doc_id", Required: false, Type: "string"}},
		Flags: []manifest.Flag{
			{Name: "since", Type: "int"},
			{Name: "limit", Type: "int"},
			{Name: "payload", Type: "bool"},
		},
	}
}

func TestTaskEventsOptionalDocIDRidesAsQuery(t *testing.T) {
	cmd := eventsCmd()

	args, err := bindArgs(cmd, []string{"tlv-bl-events-actor-attribution"})
	if err != nil {
		t.Fatalf("bindArgs refused the positional the manifest declares: %v", err)
	}
	if got := args["doc_id"]; got != "tlv-bl-events-actor-attribution" {
		t.Fatalf("doc_id = %q, want the positional", got)
	}

	// The arg is NOT a path placeholder, so it must reach the server as a query
	// param. If it silently vanished here the caller would read the GLOBAL feed
	// as if it were one row's history — a wrong answer at rc=0, which is the
	// failure this arm exists to make loud.
	got := applyQuery("/v1/tasks/events", globals{}, cmd, map[string][]string{}, args)
	want := "/v1/tasks/events?doc_id=tlv-bl-events-actor-attribution"
	if got != want {
		t.Fatalf("applyQuery = %q, want %q", got, want)
	}
}

func TestTaskEventsDocIDStaysOptional(t *testing.T) {
	cmd := eventsCmd()

	// The global feed — every existing poller. No positional, no error, and NO
	// `doc_id=` key: the request must stay byte-identical to what it always was.
	args, err := bindArgs(cmd, nil)
	if err != nil {
		t.Fatalf("bindArgs made the optional arg required: %v", err)
	}
	if _, ok := args["doc_id"]; ok {
		t.Fatalf("an absent positional bound a key: %v", args)
	}
	if got := applyQuery("/v1/tasks/events", globals{}, cmd, map[string][]string{}, args); got != "/v1/tasks/events" {
		t.Fatalf("applyQuery = %q, want the bare path", got)
	}

	// An empty-string positional counts as absent too (bindArgs' rule), so
	// `bp task events ""` is the global feed rather than a doc_id of "".
	args, err = bindArgs(cmd, []string{""})
	if err != nil {
		t.Fatalf("an empty positional errored: %v", err)
	}
	if _, ok := args["doc_id"]; ok {
		t.Fatalf("an empty positional bound a key: %v", args)
	}

	// And a SECOND positional is still refused — the arg list grew by one, not
	// into a free-for-all.
	if _, err := bindArgs(cmd, []string{"a", "b"}); err == nil {
		t.Fatal("two positionals were accepted; the binder must still refuse the extra")
	}
}
