package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// ── THE MIRROR LOCK ─────────────────────────────────────────────────────────
//
// The do-not-build vocabulary and its PRECEDENCE now sit on two surfaces,
// Elixir and Go. "Both sides are tested" is not a lock: change one and both
// suites stay green while `bp task ready` and `GET /v1/tasks/ready` disagree.
//
// serverDispatchMarkersPath is READ, never written — api/ is another fence.
// It is the SOURCE OF TRUTH (api/lib/barkpark/tasks/dispatchability.ex reads
// this same file at compile time); dispatch_markers.json beside this test is a
// byte copy. The expected value below is therefore DERIVED from the source of
// truth rather than typed a second time, which is the difference between a
// guard and a tautology.
const serverDispatchMarkersPath = "../../api/priv/tasks/dispatch_markers.json"

// TestDispatchMarkerSpecMirrorsTheServerCopy is the drift refusal. It compares
// the fully decoded documents, so a key this side does not model still counts,
// and it compares ARRAY ORDER, because precedence IS the order: a spec with
// ["deferred","forbidden"] has the same value set and the opposite meaning.
func TestDispatchMarkerSpecMirrorsTheServerCopy(t *testing.T) {
	serverRaw, err := os.ReadFile(serverDispatchMarkersPath)
	if err != nil {
		t.Fatalf("the server copy is the artifact both sides are measured against; without it this test asserts nothing: %v", err)
	}

	var server, local any
	if err := json.Unmarshal(serverRaw, &server); err != nil {
		t.Fatalf("%s is unreadable: %v", serverDispatchMarkersPath, err)
	}
	if err := json.Unmarshal(dispatchMarkerSpecJSON, &local); err != nil {
		t.Fatalf("the embedded dispatch_markers.json is unreadable: %v", err)
	}

	if !reflect.DeepEqual(server, local) {
		t.Fatalf("DRIFT: internal/cli/dispatch_markers.json is no longer the document %s holds.\n"+
			"The vocabulary and its precedence are ONE value on TWO surfaces; two green suites cannot see this.\n"+
			"server: %s\nlocal:  %s", serverDispatchMarkersPath, serverRaw, dispatchMarkerSpecJSON)
	}

	// NON-VACUITY. Every assertion above passes over two empty documents, and
	// an empty spec makes formatTaskDispatchAdvisory silent on every page —
	// the exact "0 of 400" shape this whole row exists to make impossible.
	spec := loadDispatchMarkerSpec()
	if len(spec.Classes) < 2 {
		t.Fatalf("the spec declares %d class(es); with fewer than two there is no precedence to pin", len(spec.Classes))
	}
	if len(spec.Fields) != 3 {
		t.Fatalf("the spec scans %v; the row this exists for records markers in ALL THREE of description, disposition_reason and operating_instruction, and searching any one undercounts", spec.Fields)
	}
	if len(spec.Markers) < 4 {
		t.Fatalf("the spec carries %d marker(s) — too few to be the vocabulary it claims to be", len(spec.Markers))
	}
	sensitive, insensitive := 0, 0
	for _, m := range spec.Markers {
		if m.Class == "" || m.Needle == "" {
			t.Fatalf("marker %+v has an empty class or needle; an empty needle matches EVERY row", m)
		}
		known := false
		for _, c := range spec.Classes {
			if c == m.Class {
				known = true
			}
		}
		if !known {
			t.Fatalf("marker %+v carries class %q, which is absent from classes %v — it can never be ranked, so it would be silently dropped by the renderer", m, m.Class, spec.Classes)
		}
		if m.CaseSensitive {
			sensitive++
		} else {
			insensitive++
		}
	}
	// Both arms exist ON PURPOSE (the shouted BACKLOG spellings are
	// case-sensitive because the lowercase word is prose). A spec that lost one
	// arm would still pass every check above.
	if sensitive == 0 || insensitive == 0 {
		t.Fatalf("case_sensitive arms: %d sensitive, %d insensitive — the spec needs both; the lowercase `backlog` was measured and refused precisely because it is prose", sensitive, insensitive)
	}
}

// ── CRITERION 2: THE CONTROL ────────────────────────────────────────────────
//
// A row KNOWN to carry a marker and a row KNOWN not to, both through the
// changed path, with DIFFERING output. The negative arm is the one that
// matters: an absence must mean the signal was looked for and not found, not
// that the field was never populated. `DispatchKeyPresent` is what makes that
// distinguishable, and the last sub-test below is the vacuous page the first
// census actually produced.

const dispatchControlMarked = `{"ok":true,"docs":[
  {"doc_id":"task-marked","title":"a row whose author refused it","dispatch":"forbidden"},
  {"doc_id":"task-clean","title":"an ordinary slice"}
]}`

const dispatchControlClean = `{"ok":true,"docs":[
  {"doc_id":"task-clean-a","title":"an ordinary slice"},
  {"doc_id":"task-clean-b","title":"another ordinary slice","dispatch":"delegated"}
]}`

func TestDispatchAdvisoryDiscriminatesMarkedFromClean(t *testing.T) {
	spec := loadDispatchMarkerSpec()
	shape := taskReadShapes()[taskReadyCommandID]

	marked, err := readTaskDispatch([]byte(dispatchControlMarked), taskReadyCommandID, shape, spec.Classes)
	if err != nil {
		t.Fatalf("the MARKED control page must be readable: %v", err)
	}
	clean, err := readTaskDispatch([]byte(dispatchControlClean), taskReadyCommandID, shape, spec.Classes)
	if err != nil {
		t.Fatalf("the CLEAN control page must be readable: %v", err)
	}

	markedLine := formatTaskDispatchAdvisory(marked, spec)
	cleanLine := formatTaskDispatchAdvisory(clean, spec)

	if markedLine == cleanLine {
		t.Fatalf("THE CONTROL FAILED: both control pages produced the same output %q. A signal that cannot tell a marked row from a clean one is theatre.", markedLine)
	}
	if !strings.Contains(markedLine, "DO NOT DISPATCH") || !strings.Contains(markedLine, "task-marked") {
		t.Fatalf("the marked page must name the row and refuse loudly; got %q", markedLine)
	}
	if strings.Contains(markedLine, "task-clean") {
		t.Fatalf("the marked page named an UNmarked row; got %q", markedLine)
	}
	if cleanLine != "" {
		t.Fatalf("the clean page must stay silent — a banner on every call trains the fleet to ignore it; got %q", cleanLine)
	}

	// THE NEGATIVE ARM IS ONLY EVIDENCE IF THE FIELD WAS THERE TO READ. The
	// clean page's silence is a real "looked and found none": one of its rows
	// carries a `dispatch` key (with a non-blocking class), so the projection
	// demonstrably emits the field.
	if clean.DispatchKeyPresent == 0 {
		t.Fatalf("the CLEAN control carries no `dispatch` key on any row, so its silence proves nothing — that is the vacuous '0 of 400' shape, not a clean page")
	}
	if clean.Rows != 2 || marked.Rows != 2 {
		t.Fatalf("both control pages must carry 2 rows; marked=%d clean=%d", marked.Rows, clean.Rows)
	}
	if got := marked.BlockedCount(); got != 1 {
		t.Fatalf("the marked page carries exactly one blocked row; got %d", got)
	}
	if got := clean.Other; len(got) != 1 || got[0] != "delegated" {
		t.Fatalf("the clean page's non-blocking value must be reported as OTHER, not silently dropped; got %v", got)
	}
}

// A VACUOUS page — no row carries the key at all — must be distinguishable from
// a clean one. This is the census that answered "0 of 400" off a projection
// with no content: the same silence, and none of it evidence.
func TestDispatchAdvisorySeparatesVacuousFromClean(t *testing.T) {
	spec := loadDispatchMarkerSpec()
	shape := taskReadShapes()[taskReadyCommandID]

	vacuous, err := readTaskDispatch([]byte(`{"ok":true,"docs":[{"doc_id":"a"},{"doc_id":"b"}]}`), taskReadyCommandID, shape, spec.Classes)
	if err != nil {
		t.Fatalf("readable: %v", err)
	}
	if vacuous.DispatchKeyPresent != 0 {
		t.Fatalf("this page carries no dispatch key; got DispatchKeyPresent=%d", vacuous.DispatchKeyPresent)
	}
	if formatTaskDispatchAdvisory(vacuous, spec) != "" {
		t.Fatal("a page with no signal must not manufacture one")
	}
	if vacuous.Rows != 2 {
		t.Fatalf("Rows=%d; the report must still state its denominator — a count without one is the defect", vacuous.Rows)
	}
}

// An unreadable page returns ErrReadyPageUnreadable, NEVER a verdict: a failed
// read must not be byte-identical to "nothing here is forbidden".
func TestDispatchAdvisoryRefusesRatherThanReportingZero(t *testing.T) {
	spec := loadDispatchMarkerSpec()
	shape := taskReadShapes()[taskReadyCommandID]

	for name, body := range map[string]string{
		"empty":         ``,
		"not json":      `<html>`,
		"docs is a map": `{"docs":{"a":1}}`,
	} {
		report, err := readTaskDispatch([]byte(body), taskReadyCommandID, shape, spec.Classes)
		if !errors.Is(err, ErrReadyPageUnreadable) {
			t.Fatalf("%s: want ErrReadyPageUnreadable, got err=%v report=%+v", name, err, report)
		}
		if report.BlockedCount() != 0 || report.Rows != 0 {
			t.Fatalf("%s: a refusal must carry no verdict; got %+v", name, report)
		}
	}
}

// THE BLAST RADIUS of the one production caller: which verbs speak, and that
// stdout is never touched. Unlike its claim-path sibling this one speaks in
// HUMAN mode too — its reader is a lead skimming a table.
func TestDispatchAdvisoryBlastRadius(t *testing.T) {
	cases := []struct {
		name     string
		id       string
		status   int
		body     string
		wantLine bool
	}{
		{"ready, a marked row", taskReadyCommandID, 200, dispatchControlMarked, true},
		{"ls, a marked row", taskLsCommandID, 200, dispatchControlMarked, true},
		{"prime, a marked row", taskPrimeCommandID, 200, `{"ok":true,"in_progress":[],"ready":[{"doc_id":"task-marked","dispatch":"deferred"}]}`, true},
		{"a clean page stays silent", taskReadyCommandID, 200, dispatchControlClean, false},
		{"not a 2xx", taskReadyCommandID, 404, dispatchControlMarked, false},
		{"another noun", "doc.ls", 200, dispatchControlMarked, false},
		{"task get is single-row", taskGetCommandID, 200, dispatchControlMarked, false},
		{"an unreadable page never speaks", taskReadyCommandID, 200, `<html>502</html>`, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			cmd := manifest.Command{ID: tc.id, Noun: "task", Verb: strings.TrimPrefix(tc.id, "task.")}
			emitTaskDispatchAdvisory(out, cmd, tc.status, []byte(tc.body))

			spoke := strings.Contains(stderr.String(), "DO NOT DISPATCH")
			if spoke != tc.wantLine {
				t.Errorf("advisory spoke = %v, want %v: %q", spoke, tc.wantLine, stderr.String())
			}
			if stdout.Len() != 0 {
				t.Errorf("the advisory wrote to STDOUT, so `-o json` is no longer one document: %q", stdout.String())
			}
		})
	}
}
