package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"
)

// fleetRosterPayload is the live shape behind this row: `bp fleet roster` pages
// of listener documents. NOTE WHAT IS NOT THERE — no _id, no id, no title, no
// name, no subject, no slug. A roster row carries no conventional identity key
// at all; the cell naming WHICH listener the row is about is "worker". That is
// the whole reason the old lead list mis-sorted this table: "status" was the
// only lead column it matched, and everything else — "worker" included — fell
// into the alphabetical tail, so the subject of the row rendered LAST.
const fleetRosterPayload = `{"documents":[
  {"status":"idle","agent":"listener","capacity":2,"last_seen":"2026-09-16T04:10:02Z","scope":"cli","ttl_s":900,"worker":"lead-cli-r20"},
  {"status":"busy","agent":"listener","capacity":1,"last_seen":"2026-09-16T04:09:47Z","scope":"api","ttl_s":900,"worker":"lead-api-r20"},
  {"status":"stale","agent":"listener","capacity":4,"last_seen":"2026-09-16T03:11:00Z","scope":"gates","ttl_s":900,"worker":"lead-gates-r20"}
]}`

// THE RED-WHEN-REVERTED ARM. A roster table leads WORKER, then status. Remove
// "worker" from pickColumns' lead list (the one-token revert this guards) and
// the header becomes `status agent capacity last_seen scope ttl_s worker` —
// both the order assertion and the golden red immediately.
func TestRosterTableLeadsWorkerThenStatus(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(fleetRosterPayload))

	assertGolden(t, "table_fleet_roster_worker_first", stdout.String())

	header := strings.SplitN(stdout.String(), "\n", 2)[0]
	got := strings.Fields(header)
	want := []string{"worker", "status", "agent", "capacity", "last_seen", "scope", "ttl_s"}
	if !equalStrings(got, want) {
		t.Fatalf("roster column order = %v, want %v\n%s", got, want, stdout.String())
	}
	// The two cells an operator scans for — who, and how they are — must be the
	// first two columns, so a narrow terminal that shears the right-hand tail
	// still answers the question the command was run to ask.
	if got[0] != "worker" || got[1] != "status" {
		t.Fatalf("worker+status must be the two leading columns, got %v", got[:2])
	}
}

// Narrow-terminal budget: promoting a column must not widen the table. Every
// rendered line stays inside a conservative 80-cell terminal, and the worker +
// status prefix — everything an 40-column pane would show — is itself short
// enough to survive that shear intact.
func TestRosterTableFitsNarrowTerminal(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(fleetRosterPayload))

	lines := strings.Split(strings.TrimRight(stdout.String(), "\n"), "\n")
	for _, line := range lines {
		if n := utf8.RuneCountInString(line); n > 80 {
			t.Errorf("roster line exceeds an 80-cell terminal (%d):\n%s", n, line)
		}
	}
	// worker (14) + gap (2) + status (6) must fit a 40-column pane with room to
	// spare, which is what makes leading with them worth anything.
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		prefix := strings.Index(line, fields[1]) + len(fields[1])
		if prefix > 40 {
			t.Errorf("worker+status prefix needs %d cells — past a 40-column pane:\n%s", prefix, line)
		}
	}
}

// THE QUIET ARM, part 1. A NON-roster table is untouched: a task page still
// leads _id/title/status exactly as before, because "worker" is not a key on
// those rows. A fix that reshuffled the lead list generally — say, moving
// "status" behind everything — would red here while the roster test above still
// passed.
func TestNonRosterTableColumnOrderUnchanged(t *testing.T) {
	const taskPage = `{"documents":[
  {"_id":"task-a","title":"Ship the thing","status":"open","priority":1},
  {"_id":"task-b","title":"Fix the other","status":"done","priority":2}
]}`
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	renderTable(w, []byte(taskPage))

	header := strings.SplitN(stdout.String(), "\n", 2)[0]
	got := strings.Fields(header)
	want := []string{"_id", "title", "status", "priority"}
	if !equalStrings(got, want) {
		t.Fatalf("a table with no worker key must be byte-unchanged; order = %v, want %v", got, want)
	}
}

// THE QUIET ARM, part 2. The machine views are not the table view. -o json
// round-trips the payload and -o yaml sorts keys alphabetically; NEITHER
// consults pickColumns, so both are identical before and after this change.
// These goldens stay quiet on the revert — they are here to catch the opposite
// mistake, a "column order" fix pushed down into the serializers where it would
// silently reorder every scripted consumer's keys.
func TestRosterMachineOutputIgnoresColumnOrder(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.renderRaw([]byte(fleetRosterPayload))
	assertGolden(t, "table_fleet_roster_json", stdout.String())

	var ystdout, ystderr bytes.Buffer
	yw := newWriter(&ystdout, &ystderr)
	yw.renderYAML(decodeAnyForTest(t, fleetRosterPayload))
	assertGolden(t, "table_fleet_roster_yaml", ystdout.String())

	// The serializers emit every key of every row — a table's column CHOICE
	// never reaches them.
	for _, k := range []string{"worker", "status", "agent", "capacity", "last_seen", "scope", "ttl_s"} {
		if !strings.Contains(stdout.String(), k) {
			t.Errorf("-o json dropped key %q", k)
		}
		if !strings.Contains(ystdout.String(), k) {
			t.Errorf("-o yaml dropped key %q", k)
		}
	}
}

// decodeAnyForTest unmarshals a fixture into the generic shape renderYAML takes.
func decodeAnyForTest(t *testing.T, payload string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(payload), &v); err != nil {
		t.Fatalf("fixture is not JSON: %v", err)
	}
	return v
}
