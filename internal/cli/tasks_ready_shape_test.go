package cli

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The three fixtures are REAL, not hand-authored shapes:
// task_ready_page.json is a verbatim six-row slice of a
// `bp task ready --limit 300 -o json` capture taken 2026-09-10 against
// guerrilla (300 rows: 284 omitted lifecycle_status, 16 carried "blocked").
// The other two are that same capture with ONE mutation each, so a green here
// is a statement about the shape the server actually emits.
const (
	readyPageFixture         = "task_ready_page.json"
	readyPageDriftedFixture  = "task_ready_page_drifted.json"  // docs[0] gains lifecycle_status:"open"
	readyPageEnvelopeFixture = "task_ready_page_wrong_envelope.json" // `docs` renamed to `documents`
)

func readReadyFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	if len(raw) == 0 {
		t.Fatalf("fixture %s is empty; an empty fixture would make every assertion below vacuous", name)
	}
	return raw
}

// TestTaskReadyPageShapeBothArms is the machine-checkable example
// docs/setup/TASK-SYSTEM.md's ready-shape contract is written against. It
// asserts BOTH arms in ONE run: a ready row has NO lifecycle_status, and a
// non-ready row HAS one. Either arm alone is satisfiable by a page that
// disproves nothing.
func TestTaskReadyPageShapeBothArms(t *testing.T) {
	report, err := checkTaskReadyPageShape(readReadyFixture(t, readyPageFixture))
	if err != nil {
		t.Fatalf("real ready page refused as unreadable: %v", err)
	}
	if !report.OK() {
		t.Fatalf("real ready page violates the documented contract: %v", report.Violations)
	}

	// ARM 1 — absence means READY.
	if report.ReadyRows == 0 {
		t.Fatalf("arm 1: no row OMITTED lifecycle_status; the fixture cannot prove absence means ready (rows=%d)", report.Rows)
	}
	// ARM 2 — presence means NOT ready.
	if report.NonReadyRows == 0 {
		t.Fatalf("arm 2: no row CARRIED lifecycle_status; the fixture cannot prove presence means not-ready (rows=%d)", report.Rows)
	}
	if report.ReadyRows+report.NonReadyRows != report.Rows {
		t.Fatalf("rows do not partition: ready=%d nonready=%d rows=%d", report.ReadyRows, report.NonReadyRows, report.Rows)
	}

	// THE CONFIDENT ZERO, stated as a number rather than as prose. This is the
	// filter a lead reaches for first, and on a page full of work it answers 0.
	if report.OpenFiltered != 0 {
		t.Fatalf("select(.lifecycle_status==\"open\") returned %d on a real ready page; the doc promises 0", report.OpenFiltered)
	}
	// Every value that IS emitted marks a NOT-ready row.
	for _, status := range report.NonReadyStatuses {
		if status == "open" || status == "" {
			t.Fatalf("lifecycle_status %q on a ready page: presence is supposed to mark a NOT-ready row", status)
		}
	}

	// THE ROW IS FLAT. `bp task get` nests under .doc.content; a ready row does not.
	if report.NestedRows != 0 {
		t.Fatalf("%d ready row(s) carry a `content` object; the doc says ready rows are FLAT", report.NestedRows)
	}
}

// TestTaskReadyPageShapeRefusesUnreadablePages pins the half that makes the
// check worth having: an unreadable page must NEVER be byte-identical to a
// pass. Each input below returns ErrReadyPageUnreadable, whose rendered message
// leads with the distinct `CANNOT READ:` token, and never a verdict.
func TestTaskReadyPageShapeRefusesUnreadablePages(t *testing.T) {
	cases := []struct {
		name string
		raw  []byte
	}{
		{"empty", []byte("")},
		{"whitespace", []byte("   \n")},
		{"truncated json", []byte(`{"ok":true,"docs":[{"doc_id":"t1"`)},
		{"html error page", []byte("<html><body>502 Bad Gateway</body></html>")},
		{"envelope is a list", []byte(`[{"doc_id":"t1"}]`)},
		{"no docs key", []byte(`{"ok":true,"page":{"returned":0}}`)},
		{"docs is not a list", []byte(`{"ok":true,"docs":{"doc_id":"t1"}}`)},
		{"docs is empty", []byte(`{"ok":true,"docs":[]}`)},
		{"row is not an object", []byte(`{"ok":true,"docs":["t1"]}`)},
		{"wrong envelope key", readReadyFixture(t, readyPageEnvelopeFixture)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			report, err := checkTaskReadyPageShape(tc.raw)
			if err == nil {
				t.Fatalf("an unreadable page returned a VERDICT (%+v) instead of refusing; that is the confident zero this check exists to catch", report)
			}
			if !errors.Is(err, ErrReadyPageUnreadable) {
				t.Fatalf("refusal is not ErrReadyPageUnreadable: %v", err)
			}
			if !strings.HasPrefix(err.Error(), "CANNOT READ:") {
				t.Fatalf("refusal does not lead with the distinct CANNOT READ token: %q", err.Error())
			}
			if report.OK() && report.Rows != 0 {
				t.Fatalf("a refused page still produced a populated report: %+v", report)
			}
		})
	}
}

// TestTaskReadyPageShapeRedsWhenReadyRowsGainLifecycleStatus is the MUTATION
// PROOF. task_ready_page_drifted.json is the real capture with exactly one
// change: docs[0] — a ready row — gains lifecycle_status:"open". If the server
// ever starts emitting the key on ready rows, the documented contract ("absence
// means ready; filtering for ==\"open\" returns zero") silently changes meaning
// for every reader written against it. This test is what turns that into a red.
func TestTaskReadyPageShapeRedsWhenReadyRowsGainLifecycleStatus(t *testing.T) {
	report, err := checkTaskReadyPageShape(readReadyFixture(t, readyPageDriftedFixture))
	if err != nil {
		t.Fatalf("drifted page refused as unreadable; it should parse and then VIOLATE: %v", err)
	}
	if report.OK() {
		t.Fatalf("a ready row carrying lifecycle_status:\"open\" passed the check; the contract is unguarded")
	}
	if report.OpenFiltered == 0 {
		t.Fatalf("the mutation was not seen: OpenFiltered=0 on the drifted fixture")
	}
	var named bool
	for _, v := range report.Violations {
		if strings.Contains(v, `lifecycle_status=="open"`) {
			named = true
		}
	}
	if !named {
		t.Fatalf("violations do not name the drift a reader must act on: %v", report.Violations)
	}
}

// TestTaskReadyPageShapeMatchesDocumentedContract pins the doc to the code. The
// sentences in docs/setup/TASK-SYSTEM.md are the deliverable; if someone
// deletes or reworks them, this reds rather than leaving the fixture guarding a
// contract nobody can read.
func TestTaskReadyPageShapeMatchesDocumentedContract(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "docs", "setup", "TASK-SYSTEM.md"))
	if err != nil {
		t.Fatalf("read TASK-SYSTEM.md: %v", err)
	}
	doc := string(raw)
	for _, must := range []string{
		"lifecycle_status",       // the field the contract is about
		`== "open"`,              // the filter that manufactures the zero
		"internal/cli/testdata/task_ready_page.json", // the fixture this test reads
		"`criterion`",                                // the criteria key, same family
	} {
		if !strings.Contains(doc, must) {
			t.Fatalf("TASK-SYSTEM.md no longer contains %q; the ready-shape contract this test guards was edited away", must)
		}
	}
}
