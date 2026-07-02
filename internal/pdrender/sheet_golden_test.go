package pdrender

import (
	"encoding/json"
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
// Extra keys (content, spans, right_aligned, styles, …) are ignored — the TUI
// consumes only the dense snapshot the renderer lifts.
type goldenParityFixture struct {
	SV        int               `json:"sv"`
	Snapshot  json.RawMessage   `json:"snapshot"`
	Expected  map[string]string `json:"expected"`
	Head      []string          `json:"head"`
	ErrorRefs []string          `json:"error_refs"`
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

	if strings.Contains(out, "unknown block") {
		t.Fatalf("sheet embed fell through to the unknown-block box:\n%s", out)
	}

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
