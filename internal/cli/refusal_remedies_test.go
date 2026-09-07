package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// renderUsageCommandForTest runs the REAL help render (usageCommand) and hands
// back what a caller at a terminal would read. Criterion 2 forbids satisfying
// it by source inspection, so every help assertion here goes through the same
// function `bp <noun> <verb> --help` calls.
func renderUsageCommandForTest(t *testing.T, cmd manifest.Command) string {
	t.Helper()
	var stdout, stderr bytes.Buffer
	usageCommand(newWriter(&stdout, &stderr), cmd)
	return stderr.String()
}

// taskReadbackForTest is a published (non-draft) read-back, so a receipt built
// from it is judged on what it holds rather than on which row answered.
func taskReadbackForTest() apiclient.TaskReadback {
	return apiclient.TaskReadback{DocID: "task-abc", Status: "published"}
}

// ─── (A) --miss never lowers met, and the output must name the verb that does ──

// TestMissOnAMetRowNamesWithdraw is the RED-WITHOUT anchor for instance (3).
// The mutation this test is written against is "stop naming --withdraw at the
// point of confusion" — delete the flag from missLeftMetTrueNote (or make the
// predicate return "") and THIS test reds by name, not a generic failure
// somewhere else.
func TestMissOnAMetRowNamesWithdraw(t *testing.T) {
	req := stampRequest{docID: "task-abc", worker: "w1", index: 3, miss: true, note: "did not land"}
	stored := taskboard.CriterionItem{Criterion: "prove it", Met: true}

	note := missLeftMetTrueNote(req, stored)
	if note == "" {
		t.Fatalf("a --miss stamped on a row whose stored met is TRUE produced no advisory: " +
			"that is the exact moment the caller learns --miss did not lower met, and it must name --withdraw")
	}
	if !strings.Contains(note, "--withdraw") {
		t.Errorf("the --miss advisory does not name --withdraw, the verb that DOES lower met.\ngot: %s", note)
	}
	// The remedy has to be REACHABLE, not merely named: the advisory carries a
	// runnable invocation with this row's own id and criterion index.
	for _, want := range []string{"task-abc", "--criterion 3", "bp task stamp"} {
		if !strings.Contains(note, want) {
			t.Errorf("the --miss advisory does not carry %q, so the named remedy is not a command the caller can run.\ngot: %s", want, note)
		}
	}
}

// TestMissAdvisoryIsSilentWhenItWouldBeWrong is the positive control's other
// half: the advisory must be able to say NOTHING. A note that fires on every
// stamp is a note nobody reads, and it would be false on a --miss against a row
// that is already false (a miss doing exactly its job).
func TestMissAdvisoryIsSilentWhenItWouldBeWrong(t *testing.T) {
	cases := []struct {
		name   string
		req    stampRequest
		stored taskboard.CriterionItem
	}{
		{"miss on an already-false row", stampRequest{docID: "t", miss: true}, taskboard.CriterionItem{Met: false}},
		{"a --met stamp on a met row", stampRequest{docID: "t", met: true}, taskboard.CriterionItem{Met: true}},
		{"a --withdraw that landed", stampRequest{docID: "t", withdraw: true}, taskboard.CriterionItem{Met: false}},
		{"a --withdraw that did NOT land", stampRequest{docID: "t", withdraw: true}, taskboard.CriterionItem{Met: true}},
	}
	for _, c := range cases {
		if note := missLeftMetTrueNote(c.req, c.stored); note != "" {
			t.Errorf("%s: advisory fired when it should be silent: %s", c.name, note)
		}
	}
}

// TestMissAdvisoryIsNotAFailure guards the one thing that would make this fix
// worse than the defect: the miss really did land, so it must not be reported
// as a problem or flip the exit code. stampMismatches is the verdict's problem
// list — the advisory must not be in it.
func TestMissAdvisoryIsNotAFailure(t *testing.T) {
	req := stampRequest{docID: "task-abc", index: 0, miss: true, note: "n"}
	stored := taskboard.CriterionItem{Met: true, Attempts: []taskboard.CriterionAttempt{{Note: "n"}}}
	if problems := stampMismatches(req, stored); len(problems) != 0 {
		t.Fatalf("a landed --miss was reported as %d problem(s) — the write DID land; the remedy is an advisory, not a red: %v",
			len(problems), problems)
	}
	r := stampReceipt(req, stored, taskReadbackForTest(), nil, true)
	notes, ok := r["notes"].([]string)
	if !ok || len(notes) != 1 || !strings.Contains(notes[0], "--withdraw") {
		t.Fatalf("the machine receipt does not carry the --withdraw advisory under `notes`: %#v", r["notes"])
	}
	if r["confirmed"] != true {
		t.Errorf("the advisory must not un-confirm a write that landed; confirmed=%v", r["confirmed"])
	}
}

// TestStampHelpNamesTheLoweringVerb is criterion 2's sibling for instance (3):
// the help RENDER must name --withdraw beside --miss. The manifest's own
// --miss summary is server-owned (api/lib/barkpark/plugins/tasks.ex), so this
// is the CLI-side half.
func TestStampHelpNamesTheLoweringVerb(t *testing.T) {
	lines := strings.Join(stampOutcomeHelpLines(), "\n")
	for _, want := range []string{"--met", "--miss", "--withdraw", "met is UNCHANGED", "met → FALSE"} {
		if !strings.Contains(lines, want) {
			t.Errorf("bp task stamp --help outcome block does not contain %q:\n%s", want, lines)
		}
	}
}

// TestStampHelpBlockIsRenderedByUsage runs the actual help render for the
// manifest command id the block is keyed on, so a wiring slip in usage.go (the
// block written but never reached) cannot pass the test above.
func TestStampHelpBlockIsRenderedByUsage(t *testing.T) {
	help := renderUsageCommandForTest(t, manifest.Command{
		ID: taskStampCommandID, Noun: "task", Verb: "stamp",
		Summary: "Stamp one acceptance criterion.", Writes: true,
	})
	if !strings.Contains(help, "--withdraw  met → FALSE") {
		t.Fatalf("usageCommand did not render the stamp outcome block for %s:\n%s", taskStampCommandID, help)
	}
}

// ─── (B) the envelope key is discoverable from --help, and it is CHECKED ──────

// TestListEnvelopeHelpNamesKeyAndIDField is criterion 2 at the unit level for
// the three verbs the row measured. The end-to-end proof is the recorded
// `--help` run in the PR body; this is the guard that keeps it true.
func TestListEnvelopeHelpNamesKeyAndIDField(t *testing.T) {
	cases := []struct {
		id, noun, verb, key, idField string
	}{
		{"task.ready", "task", "ready", "docs", "doc_id"},
		{"task.ls", "task", "ls", "docs", "doc_id"},
		{"doc.ls", "doc", "ls", "documents", "_id"},
	}
	for _, c := range cases {
		help := renderUsageCommandForTest(t, manifest.Command{
			ID: c.id, Noun: c.noun, Verb: c.verb, Paginated: true, Summary: "…",
		})
		if !strings.Contains(help, "."+c.key+"[]") {
			t.Errorf("bp %s %s --help never names its envelope key .%s[] — a parser has to guess, and a wrong guess reads ZERO rows:\n%s",
				c.noun, c.verb, c.key, help)
		}
		if !strings.Contains(help, "."+c.key+"[]."+c.idField) {
			t.Errorf("bp %s %s --help never names the id field .%s[].%s:\n%s", c.noun, c.verb, c.key, c.idField, help)
		}
	}
}

// TestListEnvelopeHelpIsSilentForUnrecordedCommands is the positive control on
// the help side: the block must be able to print NOTHING. A help that invents
// an envelope key for a single-object read (`doc get`, `auth me`) would be the
// same defect wearing the fix's clothes.
func TestListEnvelopeHelpIsSilentForUnrecordedCommands(t *testing.T) {
	for _, id := range []string{"doc.get", "auth.me", "workspace.create"} {
		if lines := listEnvelopeHelpLines(manifest.Command{ID: id, Noun: "x", Verb: "y"}); len(lines) != 0 {
			t.Errorf("%s is not a recorded list envelope but help rendered %d lines: %v", id, len(lines), lines)
		}
	}
}

// TestEveryRecordedEnvelopeKeyIsRenderable walks the WHOLE registry, not the
// three verbs the row happened to measure — the shape this row is about is a
// defect that appeared twice because it was fixed at the callers.
func TestEveryRecordedEnvelopeKeyIsRenderable(t *testing.T) {
	known := map[string]bool{}
	for _, k := range listEnvelopeKeys {
		known[k] = true
	}
	for id, env := range commandListEnvelopes {
		if env.Key == "" {
			t.Errorf("%s records an empty envelope key", id)
			continue
		}
		if !known[env.Key] {
			t.Errorf("%s documents envelope key %q, which listEnvelopeKeys (table.go) does not know — the help would name a key the renderer cannot read", id, env.Key)
		}
		lines := listEnvelopeHelpLines(manifest.Command{ID: id, Noun: "n", Verb: "v"})
		if len(lines) == 0 {
			t.Errorf("%s is in the registry but rendered no help lines", id)
		}
	}
}

// TestListEnvelopeDriftCatchesAWrongKey is the check that keeps the documented
// key from becoming another unfalsifiable promise: it reads the REAL response
// and reds when the help is wrong. The inputs below were not written against
// the implementation's happy path — a body under the wrong key, a body whose
// rows lack the documented id field — which is the positive control criterion 3
// asks for.
func TestListEnvelopeDriftCatchesAWrongKey(t *testing.T) {
	ready := manifest.Command{ID: "task.ready", Noun: "task", Verb: "ready"}

	// 1. The rows arrived under a DIFFERENT known key than the help promised.
	body := []byte(`{"ok":true,"documents":[{"_id":"task-1"}]}`)
	note := listEnvelopeDrift(ready, 200, body)
	if note == "" || !strings.Contains(note, ".docs") || !strings.Contains(note, ".documents") {
		t.Errorf("drift check missed rows arriving under `documents` while the help documents `docs`: %q", note)
	}

	// 2. The key is right and the id field is not there.
	body = []byte(`{"ok":true,"docs":[{"id":"task-1","title":"t"}]}`)
	note = listEnvelopeDrift(ready, 200, body)
	if note == "" || !strings.Contains(note, "doc_id") {
		t.Errorf("drift check missed rows with no `doc_id` while the help documents .docs[].doc_id: %q", note)
	}

	// 3. THE HONEST READ IS SILENT — including a genuinely empty page, which
	//    must never be reported as drift (that would re-create the very
	//    ambiguity this row is about).
	for _, ok := range []string{
		`{"ok":true,"docs":[{"doc_id":"task-1","title":"t"}]}`,
		`{"ok":true,"docs":[]}`,
		`{"ok":true,"page":{"has_more":false}}`,
	} {
		if note := listEnvelopeDrift(ready, 200, []byte(ok)); note != "" {
			t.Errorf("drift check fired on an honest read %s: %s", ok, note)
		}
	}

	// 4. It reads NOTHING it was not asked to: a non-2xx, an unparseable body,
	//    and a command with no recorded envelope all stay silent.
	if note := listEnvelopeDrift(ready, 500, []byte(`{"documents":[{"_id":"x"}]}`)); note != "" {
		t.Errorf("drift check fired on a 500: %s", note)
	}
	if note := listEnvelopeDrift(ready, 200, []byte(`<html>proxy</html>`)); note != "" {
		t.Errorf("drift check fired on an unparseable body: %s", note)
	}
	if note := listEnvelopeDrift(manifest.Command{ID: "doc.get", Noun: "doc", Verb: "get"}, 200,
		[]byte(`{"documents":[{"_id":"x"}]}`)); note != "" {
		t.Errorf("drift check fired on an unrecorded command: %s", note)
	}
}

// TestDriftCheckWouldHaveCaughtTheMeasuredMisread replays the incident the row
// records: a parser keyed on `tasks`/`id` read ZERO rows out of a real response
// and printed a confident empty queue. Nothing warned. The assertion is that a
// response shaped like the WRONG expectation is now named as drift rather than
// read as emptiness.
func TestDriftCheckWouldHaveCaughtTheMeasuredMisread(t *testing.T) {
	ready := manifest.Command{ID: "task.ready", Noun: "task", Verb: "ready"}
	// The shape the burned parser believed in.
	wrong := map[string]any{"ok": true, "tickets": []any{map[string]any{"id": "task-1"}}}
	raw, err := json.Marshal(wrong)
	if err != nil {
		t.Fatal(err)
	}
	note := listEnvelopeDrift(ready, 200, raw)
	if note == "" {
		t.Fatalf("a task.ready response carrying its rows under a key the help does not document produced no warning — " +
			"the empty read and the empty result stay indistinguishable")
	}
	if !strings.Contains(note, "docs") {
		t.Errorf("the drift note does not name the key the caller should read: %s", note)
	}
}
