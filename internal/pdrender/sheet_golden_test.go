package pdrender

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go end of the cross-surface golden-parity spine. ONE canonical sheet is
// synthesised by Elixir (Core.snapshot_for + Fmt.display), committed as
// testdata/sheet-golden-parity.json, and mirrored byte-for-byte into the api
// test-support and web fixture trees. The Elixir freshness lock
// (golden_parity_fixture_test.exs) proves the fixture still equals the
// generator; THIS test proves the TUI's sheet-embed adapter (sheet.go) renders
// that same snapshot faithfully — the same values every other surface shows.
//
// Before this fixture the Go side (sheet_test.go) tested only width math and
// hand-typed samples sharing no values with the canonical sheet, so an sv bump
// or a Fmt.display change could ship with every gate green and the TUI drawing
// a wrong/empty grid. This closes that gap and adds the sv tripwire below.

// goldenParityFixture is the subset of the shared fixture this surface reads.
// Extra keys (content, right_aligned, styles, …) are ignored — the TUI
// consumes only the dense snapshot the renderer lifts.
type goldenParityFixture struct {
	SV        int               `json:"sv"`
	Snapshot  json.RawMessage   `json:"snapshot"`
	Expected  map[string]string `json:"expected"`
	Head      []string          `json:"head"`
	ErrorRefs []string          `json:"error_refs"`
	// Spans maps a merge-anchor A1 ref to its [colspan, rowspan]. Optional —
	// when the generated fixture omits it the span asserts are skipped (the
	// fixture-coverage slice populates it); when present, every covered
	// non-anchor position must be empty in both the snapshot and the render.
	Spans map[string][2]int `json:"spans"`
}

func loadGoldenParityFixture(t *testing.T) goldenParityFixture {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "sheet-golden-parity.json"))
	if err != nil {
		t.Fatalf("read golden-parity fixture: %v", err)
	}
	var fx goldenParityFixture
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode golden-parity fixture: %v", err)
	}
	// Floor guards: the fixture is generated (`mix barkpark.sheets.gen_golden_parity`);
	// a gutted or truncated regen must RED here instead of silently shrinking
	// what every test below covers.
	if fx.SV == 0 {
		t.Fatalf("fixture floor: sv is missing/zero — regen produced an unstamped fixture")
	}
	if len(fx.Snapshot) == 0 {
		t.Fatalf("fixture floor: snapshot is missing/empty")
	}
	if len(fx.Expected) < 20 {
		t.Fatalf("fixture floor: expected has %d entries, floor is 20 — regen dropped coverage", len(fx.Expected))
	}
	if len(fx.Head) < 3 {
		t.Fatalf("fixture floor: head has %d labels, floor is 3 — regen dropped coverage", len(fx.Head))
	}
	if len(fx.ErrorRefs) < 3 {
		t.Fatalf("fixture floor: error_refs has %d entries, floor is 3 — regen dropped coverage", len(fx.ErrorRefs))
	}
	return fx
}

// rowOf returns the 1-based row number embedded in an A1 ref ("B2" -> 2). Head
// cells live on row 1 (they render UPPERCASED); everything else is a body cell
// (rendered verbatim).
func rowOf(ref string) int {
	i := strings.IndexFunc(ref, func(r rune) bool { return r >= '0' && r <= '9' })
	if i < 0 {
		return 0
	}
	n := 0
	for _, r := range ref[i:] {
		if r < '0' || r > '9' {
			break
		}
		n = n*10 + int(r-'0')
	}
	return n
}

// colOf returns the 1-based column number embedded in an A1 ref ("B2" -> 2,
// "AA3" -> 27), or 0 when the ref has no leading letters.
func colOf(ref string) int {
	n := 0
	for _, r := range ref {
		if r < 'A' || r > 'Z' {
			break
		}
		n = n*26 + int(r-'A'+1)
	}
	return n
}

// TestSheetGoldenParitySV is the schema-version tripwire. sheet.go lifts the
// snapshot with NO sv awareness while Core pins @snapshot_schema_version. If a
// Core bump regenerates the fixture (Elixir freshness stays green) but nobody
// re-examines the sv-blind lift here, this reds — forcing that review.
func TestSheetGoldenParitySV(t *testing.T) {
	fx := loadGoldenParityFixture(t)
	if fx.SV != supportedSheetSnapshotSV {
		t.Fatalf("fixture sv = %d, but sheet.go supportedSheetSnapshotSV = %d — "+
			"Core.@snapshot_schema_version bumped; re-examine the sv-blind snapshot lift in "+
			"sheetBlockRenderer.Render before updating this const", fx.SV, supportedSheetSnapshotSV)
	}
}

// TestSheetGoldenParityRender renders the canonical snapshot through the real
// "sheet" embed path (Decode -> RenderDoc, the same seam a paper uses) and
// asserts every value the Elixir source-of-truth produced survives to the TUI:
// head labels uppercased, body values (numbers, fmt classes, bools, a date,
// three error codes, merge anchors) verbatim, no unknown-block fallback, no
// spurious truncation note.
func TestSheetGoldenParityRender(t *testing.T) {
	fx := loadGoldenParityFixture(t)
	reg := testRegistry()

	// Wrap the fixture's snapshot VERBATIM in the authored embed shape the API
	// serves — {"type":"sheet","ref":…,"snapshot":{…}}.
	blockJSON := []byte(`[{"type":"sheet","ref":"golden","snapshot":` + string(fx.Snapshot) + `}]`)
	blocks, err := Decode(blockJSON)
	if err != nil {
		t.Fatalf("decode sheet embed block: %v", err)
	}

	// Width 200 leaves ample room so no cell truncates — a truncation flake
	// would otherwise hide a real value from the substring assertions.
	ctx := RenderCtx{Width: 200, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))

	assertNoUnknownBlock(t, "sheet-golden-parity.json", out)

	// The snapshot is small and Width 200 is generous — the grid must NOT
	// report truncation (that note only appears for a position-cap clip).
	if strings.Contains(out, "Sheet truncated") {
		t.Errorf("unexpected truncation note for a tiny sheet:\n%s", out)
	}

	// Every head label renders UPPERCASED (PdTable/PdSheet head treatment).
	for _, label := range fx.Head {
		if want := strings.ToUpper(label); !strings.Contains(out, want) {
			t.Errorf("head label %q (uppercased %q) missing from render:\n%s", label, want, out)
		}
	}

	// Every value the Elixir snapshot produced must survive to the TUI. Head
	// cells (row 1) render uppercased; body cells verbatim.
	for ref, val := range fx.Expected {
		if rowOf(ref) == 1 {
			if want := strings.ToUpper(val); !strings.Contains(out, want) {
				t.Errorf("head cell %s = %q (uppercased %q) missing:\n%s", ref, val, want, out)
			}
			continue
		}
		if !strings.Contains(out, val) {
			t.Errorf("body cell %s = %q missing from render (a fmt/value drift or a dropped row):\n%s", ref, val, out)
		}
	}

	// The three error codes are the wave-9 addition (row 9 + A6) — assert them
	// explicitly so a regression that drops error rendering names the code.
	for _, ref := range fx.ErrorRefs {
		code := fx.Expected[ref]
		if code == "" {
			t.Errorf("error ref %s has no expected value in the fixture", ref)
			continue
		}
		if !strings.Contains(out, code) {
			t.Errorf("error code %q (cell %s) missing from render:\n%s", code, ref, out)
		}
	}
}

// ── geometry lock ───────────────────────────────────────────────────────────
// TestSheetGoldenParityRender above is strings.Contains over the WHOLE render,
// which is mutation-blind to GEOMETRY: reversed rows, swapped columns, and a
// merge smeared across its covered cells all keep every substring present and
// stay green. The geometry test below parses the rendered border table back
// into an exact per-position grid and asserts each expected value sits at its
// MAPPED position — plus an in-test negative control (reversed rows must RED)
// so the checker itself can never rot into vacuity.

// parsedGoldenSnapshot is the dense display grid decoded from the fixture's
// snapshot (the same shape sheet.go lifts: head + rows of exact strings).
type parsedGoldenSnapshot struct {
	Head []string   `json:"head"`
	Rows [][]string `json:"rows"`
}

// renderGoldenGrid renders a snapshot through the same real embed seam the
// existing test uses (Decode -> RenderDoc, Width 200, NoColor, ansi.Strip) and
// parses the lipgloss NormalBorder table back into exact cell strings: keep
// the lines containing the vertical bar, split on it, drop the outside-border
// fragments, TrimSpace the rest. grid[0] is the header line when a head is
// present; the remaining lines are body rows in order.
func renderGoldenGrid(t *testing.T, snapshot json.RawMessage) [][]string {
	t.Helper()
	reg := testRegistry()
	blockJSON := []byte(`[{"type":"sheet","ref":"golden","snapshot":` + string(snapshot) + `}]`)
	blocks, err := Decode(blockJSON)
	if err != nil {
		t.Fatalf("decode sheet embed block: %v", err)
	}
	ctx := RenderCtx{Width: 200, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))

	var grid [][]string
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, "│") {
			continue // border/rule lines carry no vertical bar
		}
		frags := strings.Split(line, "│")
		if len(frags) < 3 {
			continue // stray bar with no enclosed cells
		}
		row := make([]string, 0, len(frags)-2)
		for _, f := range frags[1 : len(frags)-1] {
			row = append(row, strings.TrimSpace(f))
		}
		grid = append(grid, row)
	}
	return grid
}

// geometryProblems runs every positional assertion against ONE snapshot and
// returns the failures as strings instead of failing t directly — that is
// what lets the in-test negative control prove the checker REDS on a
// deliberately mutated snapshot. All loops are fixture-driven so a fixture
// regen (more rows, more expected refs, populated spans) needs no edits here.
func geometryProblems(t *testing.T, fx goldenParityFixture, snapshot json.RawMessage) []string {
	t.Helper()
	var snap parsedGoldenSnapshot
	if err := json.Unmarshal(snapshot, &snap); err != nil {
		t.Fatalf("decode snapshot head/rows: %v", err)
	}
	grid := renderGoldenGrid(t, snapshot)
	hasHead := len(snap.Head) > 0

	var problems []string
	badf := func(format string, args ...any) {
		problems = append(problems, fmt.Sprintf(format, args...))
	}

	var header []string
	body := grid
	if hasHead {
		if len(grid) == 0 {
			badf("render parsed to zero grid lines")
			return problems
		}
		header, body = grid[0], grid[1:]
	}

	// (4) The parsed body must carry EXACTLY the snapshot's rows — a dropped
	// or duplicated row is a geometry bug even if every substring survives.
	if len(body) != len(snap.Rows) {
		badf("parsed body row count = %d, snapshot has %d rows", len(body), len(snap.Rows))
	}

	// bodyIdx maps a 1-based A1 row to a body-slice index: with a head, ref
	// row 1 is the header line and body ref row N is parsed body row N-2.
	bodyIdx := func(r int) int {
		if hasHead {
			return r - 2
		}
		return r - 1
	}
	// renderedCell returns the parsed cell at a 1-based A1 (row, col).
	renderedCell := func(r, c int) (string, bool) {
		if hasHead && r == 1 {
			if c >= 1 && c <= len(header) {
				return header[c-1], true
			}
			return "", false
		}
		br := bodyIdx(r)
		if br < 0 || br >= len(body) || c < 1 || c > len(body[br]) {
			return "", false
		}
		return body[br][c-1], true
	}
	// snapshotCell returns the decoded snapshot value at a 1-based body (row, col).
	snapshotCell := func(r, c int) (string, bool) {
		br := bodyIdx(r)
		if br < 0 || br >= len(snap.Rows) || c < 1 || c > len(snap.Rows[br]) {
			return "", false
		}
		return snap.Rows[br][c-1], true
	}

	// (2) EVERY expected (ref, val) must sit at its MAPPED position, compared
	// with exact equality — no substring collisions ("1" can no longer be
	// satisfied by "1,200", "5" by "3.50"). Head cells render UPPERCASED.
	for ref, val := range fx.Expected {
		r, c := rowOf(ref), colOf(ref)
		if r == 0 || c == 0 {
			badf("expected ref %q does not parse as an A1 ref", ref)
			continue
		}
		want := val
		if hasHead && r == 1 {
			want = strings.ToUpper(val)
		}
		got, ok := renderedCell(r, c)
		if !ok {
			badf("cell %s: position (row %d, col %d) is outside the parsed grid", ref, r, c)
			continue
		}
		if got != want {
			badf("cell %s: rendered %q at (row %d, col %d), want %q exactly", ref, got, r, c, want)
		}
	}

	// (3) Merge anchors: every covered non-anchor position must be empty in
	// BOTH the rendered grid and the decoded snapshot rows — a merge smeared
	// across its covered cells is invisible to substring checks.
	for anchor, span := range fx.Spans {
		ar, ac := rowOf(anchor), colOf(anchor)
		if ar == 0 || ac == 0 {
			badf("span anchor %q does not parse as an A1 ref", anchor)
			continue
		}
		colspan, rowspan := span[0], span[1]
		for dr := 0; dr < rowspan; dr++ {
			for dc := 0; dc < colspan; dc++ {
				if dr == 0 && dc == 0 {
					continue // the anchor itself carries the value
				}
				r, c := ar+dr, ac+dc
				if got, ok := renderedCell(r, c); !ok {
					badf("merge %s: covered position (row %d, col %d) is outside the parsed grid", anchor, r, c)
				} else if got != "" {
					badf("merge %s: covered position (row %d, col %d) rendered %q, want empty", anchor, r, c, got)
				}
				if sv, ok := snapshotCell(r, c); !ok {
					badf("merge %s: covered position (row %d, col %d) is outside the snapshot rows", anchor, r, c)
				} else if sv != "" {
					badf("merge %s: covered position (row %d, col %d) is %q in the snapshot, want empty", anchor, r, c, sv)
				}
			}
		}
	}

	return problems
}

// TestSheetGoldenParityGeometry is the positional lock: parse the render back
// into a grid and pin every expected value to its exact cell, then prove the
// checker itself is alive with an in-test negative control.
func TestSheetGoldenParityGeometry(t *testing.T) {
	fx := loadGoldenParityFixture(t)

	for _, p := range geometryProblems(t, fx, fx.Snapshot) {
		t.Errorf("geometry: %s", p)
	}

	// NEGATIVE CONTROL (the load-bearing proof): deep-copy the snapshot via a
	// decode/re-encode round-trip, REVERSE its rows, re-render, and require
	// the checker to FAIL. If this ever passes, the geometry checker has
	// rotted into the same vacuity this test exists to kill.
	var mutated map[string]any
	if err := json.Unmarshal(fx.Snapshot, &mutated); err != nil {
		t.Fatalf("negative control: decode snapshot copy: %v", err)
	}
	rows, ok := mutated["rows"].([]any)
	if !ok || len(rows) < 2 {
		t.Fatalf("negative control: snapshot rows missing or too small to reverse (%d)", len(rows))
	}
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
	reversed, err := json.Marshal(mutated)
	if err != nil {
		t.Fatalf("negative control: re-encode reversed snapshot: %v", err)
	}
	if problems := geometryProblems(t, fx, reversed); len(problems) == 0 {
		t.Fatalf("NEGATIVE CONTROL FAILED: geometry checker stayed green on REVERSED snapshot rows — the checker is vacuous")
	}
}
