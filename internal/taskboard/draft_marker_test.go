package taskboard

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// ─── THE DRAFT LABEL CONTRACT, Go half ───────────────────────────────────────
//
// The contract is Barkpark.Tasks.Board's moduledoc (#18961), not re-invented
// here: a row is a draft iff its OWN stored doc_id wears the `drafts.` prefix;
// the marker is called `draft`; it is a plain bool, always present; it is
// derived at the projection boundary off the RAW id, BEFORE the strip, then
// CARRIED. These arms pin each of those clauses, each with the control that
// proves the probe was live.

// draftWireBody is a /v1/tasks list body carrying exactly the rows a test names.
// It goes through decodeTaskListFull — the REAL wire boundary — so an arm can
// never accidentally construct a Task with a hand-set Draft and call that proof.
func draftWireBody(docs ...string) []byte {
	return []byte(`{"docs":[` + strings.Join(docs, ",") + `]}`)
}

func decodeOneTask(t *testing.T, doc string) Task {
	t.Helper()
	tasks, _, err := decodeTaskListFull(draftWireBody(doc))
	if err != nil {
		t.Fatalf("decodeTaskListFull: %v", err)
	}
	if len(tasks) != 1 {
		t.Fatalf("want 1 task, got %d", len(tasks))
	}
	return tasks[0]
}

// TestDraftDerivedFromRawDocIDBeforeTheStrip is criterion 1's arm. It builds the
// task from a RAW `drafts.`-spelled id THROUGH the wire decode, because the
// failure this criterion names is silent: deriving Draft after bareID has run
// yields false for EVERY row, and a fixture built the same wrong way would agree
// with it. So the arm asserts three separate things:
//
//  1. the raw-id row reads Draft true (the subject),
//  2. the published twin reads Draft false (the CONTROL — without it, a helper
//     hard-wired to `return true` would pass arm 1), and
//  3. the post-strip derivation is explicitly demonstrated to be FALSE, so the
//     failure direction is on the record as a measurement rather than a claim.
func TestDraftDerivedFromRawDocIDBeforeTheStrip(t *testing.T) {
	draft := decodeOneTask(t, `{"doc_id":"drafts.cc-1","title":"Draft row","lifecycle_status":"open"}`)
	if !draft.Draft {
		t.Fatalf("drafts.cc-1 must read Draft true, got false — Draft is being derived after the bareID strip")
	}

	published := decodeOneTask(t, `{"doc_id":"cc-1","title":"Published row","lifecycle_status":"open"}`)
	if published.Draft {
		t.Fatalf("CONTROL: the published twin cc-1 must read Draft false, got true — the prefix test is not testing anything")
	}

	// The failure direction, measured. bareID is what the package applies at
	// every read site; running the prefix test on ITS output is the mistake this
	// criterion exists to forbid, and here is the proof that it silently reads
	// not-a-draft for a row that IS one.
	if isDraftID(bareID("drafts.cc-1")) {
		t.Fatalf("bareID no longer strips the prefix — the failure-direction arm has stopped measuring anything")
	}
	if !isDraftID("drafts.cc-1") {
		t.Fatalf("isDraftID must read the RAW id as a draft")
	}
}

// TestDraftIsSpellingNotStatus is criterion 3's arm, and the one that separates
// the spelling rule from a status check: a `drafts.`-spelled row the server
// stores with status "published" — and a done lifecycle, and no draftiness
// anywhere in its content — is STILL a draft. The mirrored control is the
// opposite corner: a BARE id stored status "draft" is NOT one. Either half alone
// is satisfiable by a status check; together they are not.
func TestDraftIsSpellingNotStatus(t *testing.T) {
	publishedSpellingDraft := decodeOneTask(t,
		`{"doc_id":"drafts.cc-2","title":"Published status, draft spelling","status":"published","lifecycle_status":"done","content":{"draft":false}}`)
	if !publishedSpellingDraft.Draft {
		t.Fatalf(`a drafts.-spelled row stored status:"published" is STILL a draft (THE DRAFT LABEL CONTRACT); got Draft=false — the marker has become a status check`)
	}

	draftStatusBareSpelling := decodeOneTask(t,
		`{"doc_id":"cc-2","title":"Draft status, published spelling","status":"draft","lifecycle_status":"open","content":{"draft":true}}`)
	if draftStatusBareSpelling.Draft {
		t.Fatalf(`CONTROL: a BARE id is not a draft however the row spells its status or content; got Draft=true — the marker is reading status or content, not the doc_id`)
	}
}

// draftBoard is one loose (no-epic) task, the smallest board that reaches
// render.go's spineTask paint path.
func draftBoard(t Task) Board {
	return Board{Orphans: []Task{t}, TaskCount: 1, OrphansActive: true}
}

// spineRowFor renders the board and returns the ansi-stripped line carrying the
// task's title. It returns the LINE, and the caller asserts on the CELL within
// it — never on the line's width. A group-level width assertion is satisfied by
// trailing spaces and would pass over a marker that never painted.
func spineRowFor(t *testing.T, task Task, width int) string {
	t.Helper()
	// CollapsedEpics pins the loose bucket EXPANDED (sectionModeFor's explicit
	// entry always wins). Without it the one-row bucket renders header-only and
	// the arm would assert over a board that painted no task row at all.
	st := UIState{Cursor: -1, CollapsedEpics: map[string]bool{orphansFoldKey: false}}
	lines, _, _ := flattenSpine(draftBoard(task), st, width, fixedNow)
	for _, ln := range lines {
		s := ansi.Strip(ln)
		if strings.Contains(s, task.Title) {
			return s
		}
	}
	t.Fatalf("no spine line carried the title %q; lines=%q", task.Title, lines)
	return ""
}

// TestBoardRowPaintsDraftMarkerAtTheTitleCell is criterion 2's board half.
//
// The assertion reads the CELL, at an offset MEASURED from a control row —
// never the row's width and never "the line contains DRAFT". A row is
// right-padded and carries its own right-meta, so a whole-line substring test is
// satisfied by a chip that landed in a meta slot (which sheds) or by trailing
// space that hides a short cell. So: render the published twin, take the column
// where its title begins, and require the draft row to open its title cell at
// THAT column with the chip followed by the title.
func TestBoardRowPaintsDraftMarkerAtTheTitleCell(t *testing.T) {
	const title = "Wire the live bridge"
	published := Task{DocID: "cc-1", Title: title, Lifecycle: lifeOpen, UpdatedAt: fixedNow}
	draft := Task{DocID: "drafts.cc-1", Title: title, Lifecycle: lifeOpen, Draft: true, UpdatedAt: fixedNow}

	plain := spineRowFor(t, published, 80)
	titleCol := strings.Index(plain, title)
	if titleCol < 0 {
		t.Fatalf("control row did not carry the title: %q", plain)
	}
	if strings.Contains(plain, draftLabel) {
		t.Fatalf("CONTROL: a published row must carry no DRAFT anywhere on the line; got %q", plain)
	}

	line := spineRowFor(t, draft, 80)
	want := draftLabel + " " + title
	if at := strings.Index(line, want); at != titleCol {
		t.Fatalf("the DRAFT chip must open the title cell at column %d (where the control row's title starts); found %q at %d in %q",
			titleCol, want, at, line)
	}
}

// TestBoardDraftMarkerSurvivesTheNarrowDegrade pins WHY the chip rides the title
// and not the right-meta. Below dropMetaBelow columns taskRowWithOutline sheds
// the meta wholesale; a marker parked there would vanish at exactly the widths
// where the reader most needs it. This arm reds if the chip is ever moved into a
// droppable meta token.
func TestBoardDraftMarkerSurvivesTheNarrowDegrade(t *testing.T) {
	// A row with real right-meta (priority + a criteria fraction), so "the meta
	// shed" is a statement about something that was actually there.
	task := Task{DocID: "drafts.cc-1", Title: "Narrow", Lifecycle: lifeOpen, Draft: true,
		Priority: "1", Criteria: &Criteria{Met: 1, Total: 4}, UpdatedAt: fixedNow}

	wide := spineRowFor(t, task, 80)
	narrow := spineRowFor(t, task, dropMetaBelow-10)

	// CONTROL FIRST: the wide row must carry meta, and the narrow row must have
	// lost it. Without both halves the arm below could be measuring the wide path
	// and would prove nothing about shedding.
	if !strings.Contains(wide, "P1") || !strings.Contains(wide, "1/4") {
		t.Fatalf("CONTROL: the wide row should carry its right-meta; got %q", wide)
	}
	if strings.Contains(narrow, "P1") || strings.Contains(narrow, "1/4") {
		t.Fatalf("CONTROL: width %d should have shed the right-meta; got %q", dropMetaBelow-10, narrow)
	}

	if !strings.Contains(narrow, draftLabel+" "+task.Title) {
		t.Fatalf("the DRAFT marker must survive the sub-%d-col degrade and stay on the title; got %q", dropMetaBelow, narrow)
	}
}

// TestDetailPaintsDraftMarkerOnItsOwnLine is criterion 2's detail half. The
// marker gets a line of its own directly under the title — asserted as a WHOLE
// line, not a substring of the meta line, because folding it in beside
// lifecycle/priority/kind is precisely the status-adjacency the contract warns
// against. The control is the same detail with Draft false.
func TestDetailPaintsDraftMarkerOnItsOwnLine(t *testing.T) {
	d := TaskDetail{Task: Task{DocID: "drafts.cc-1", Title: "Draft detail", Lifecycle: lifeOpen, Draft: true, UpdatedAt: fixedNow}}
	lines, _ := RenderTaskDetail(d, nil, 0, 80, fixedNow)

	titleAt, markerAt := -1, -1
	for i, ln := range lines {
		s := strings.TrimSpace(ansi.Strip(ln))
		if s == d.Title {
			titleAt = i
		}
		if s == draftLabel {
			markerAt = i
		}
	}
	if titleAt < 0 {
		t.Fatalf("detail lost its title line: %q", lines)
	}
	if markerAt != titleAt+1 {
		t.Fatalf("the DRAFT marker must be its OWN line directly under the title (title@%d marker@%d); lines=%q", titleAt, markerAt, lines)
	}

	d.Draft = false
	d.DocID = "cc-1"
	plain, _ := RenderTaskDetail(d, nil, 0, 80, fixedNow)
	for _, ln := range plain {
		if strings.Contains(ansi.Strip(ln), draftLabel) {
			t.Fatalf("CONTROL: a published task's detail must carry no DRAFT; found on %q", ln)
		}
	}
}

// TestDetailChildrenRailPaintsDraftMarker covers the other Task-shaped surface
// in detail_render.go: the CHILDREN rail. It is asserted at the child's title
// cell for the same reason the board row is — the rail line also carries a
// trailing age badge, so a whole-line substring test would not distinguish a
// marker on the title from one that landed in the age slot.
func TestDetailChildrenRailPaintsDraftMarker(t *testing.T) {
	parent := TaskDetail{Task: Task{DocID: "cc-goal", Title: "Goal", Lifecycle: lifeOpen, UpdatedAt: fixedNow}}
	kids := []Task{
		{DocID: "drafts.cc-1", Title: "Draft child", Lifecycle: lifeOpen, Draft: true, UpdatedAt: fixedNow},
		{DocID: "cc-2", Title: "Published child", Lifecycle: lifeOpen, UpdatedAt: fixedNow},
	}
	lines, _ := RenderTaskDetail(parent, kids, -1, 80, fixedNow)

	var draftLine, plainLine string
	for _, ln := range lines {
		s := ansi.Strip(ln)
		if strings.Contains(s, "Draft child") {
			draftLine = s
		}
		if strings.Contains(s, "Published child") {
			plainLine = s
		}
	}
	if draftLine == "" || plainLine == "" {
		t.Fatalf("children rail did not paint both rows: %q", lines)
	}
	dcell := strings.TrimLeft(draftLine, " ▎ ○·!✓✕⠋◆@")
	if !strings.HasPrefix(dcell, draftLabel+" Draft child") {
		t.Fatalf("draft child's title cell must open with %q then the title; cell=%q", draftLabel, dcell)
	}
	if strings.Contains(plainLine, draftLabel) {
		t.Fatalf("CONTROL: the published child must carry no DRAFT; got %q", plainLine)
	}
}

// TestDraftPrefixTestHasExactlyOneSite is the anti-scatter arm criterion 1 asks
// for, enforced mechanically rather than by a grep somebody has to remember to
// run. It reds the moment a second String prefix test on the drafts. spelling
// appears anywhere in the package — the exact defect the Elixir side spent a row
// consolidating into Barkpark.Content.DraftId.draft?/1.
func TestDraftPrefixTestHasExactlyOneSite(t *testing.T) {
	sites := draftPrefixTestSites(t)
	if len(sites) != 1 {
		t.Fatalf("exactly ONE drafts.-prefix test may exist in this package (isDraftID); found %d: %v", len(sites), sites)
	}
	if !strings.HasSuffix(sites[0].file, "detail_data.go") {
		t.Fatalf("the one prefix test must stay beside bareID in detail_data.go; found it in %s", sites[0].file)
	}
}

// draftSite is one source location that tests the `drafts.` spelling.
type draftSite struct {
	file string
	line int
	text string
}

// draftPrefixTestSites scans every non-test .go file in the package for a
// strings.HasPrefix TEST against the drafts. spelling, in EITHER spelling the
// package could use — the draftsPrefix const or a bare "drafts." literal — so
// re-scattering the test cannot hide behind the const. TrimPrefix is
// deliberately NOT matched: it is the STRIP (bareID), the other half of the
// pair, and conflating the two would make this guard red on the very function
// isDraftID is documented to sit beside. Comments are excluded (isDraftID's own
// doc comment quotes the very grep this enforces, and a documentation line is
// not a second implementation).
//
// It carries the positive+negative control render_clock_guard_test.go
// established: a scanner that matches nothing would report "exactly one site"
// having measured nothing at all, so the matcher is proved on both a real hit
// and a near-miss before any verdict is read.
func draftPrefixTestSites(t *testing.T) []draftSite {
	t.Helper()
	prefixTest := regexp.MustCompile(`strings\.HasPrefix\([^)]*(draftsPrefix|"drafts\.")`)

	if !prefixTest.MatchString(`return strings.HasPrefix(id, draftsPrefix)`) {
		t.Fatal("scanner does not match the const spelling — every verdict below would be vacuous")
	}
	if !prefixTest.MatchString(`if strings.HasPrefix(t.DocID, "drafts.") {`) {
		t.Fatal("scanner does not match the literal spelling — a re-scattered test would hide from it")
	}
	if prefixTest.MatchString(`if strings.HasPrefix(id, taskPrefix) {`) {
		t.Fatal("scanner matches an unrelated prefix test — it would red on correct code")
	}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}
	var sites []draftSite
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		scanned++
		for i, ln := range strings.Split(string(src), "\n") {
			if strings.HasPrefix(strings.TrimSpace(ln), "//") {
				continue // a doc comment is not a second implementation
			}
			if prefixTest.MatchString(ln) {
				sites = append(sites, draftSite{file: name, line: i + 1, text: strings.TrimSpace(ln)})
			}
		}
	}
	if scanned == 0 {
		t.Fatal("scanned 0 non-test .go files in internal/taskboard — the scan measured nothing")
	}
	return sites
}
