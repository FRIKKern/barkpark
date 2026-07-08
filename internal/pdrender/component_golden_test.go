package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go leg of the cross-surface PAPER-COMPONENT golden-parity spine. Per block
// type, ONE canonical fixture (`<type>.golden.json`) is synthesised by Elixir
// (`mix barkpark.paper_components.gen_golden_parity`) carrying the authored
// `input` block plus an `expected` STRUCTURAL PROJECTION (node roles / column
// labels / row titles / glyph-role / nesting), and mirrored byte-for-byte into
// the api and web fixture trees. The Elixir freshness lock proves the fixtures
// still equal the generator; THIS test proves the TUI's component renderers
// (taskblocks.go / gridblocks.go) realize that same projection — the shared
// contract every surface answers to.
//
// DECISION-1: the projection is the shared truth; each surface asserts its NATIVE
// realization (here: stripped-ANSI substring over the real Decode -> RenderDoc
// seam). Literal-HTML / text-normalized diffs are rejected — the TUI emits ANSI
// and the surfaces share no prose (e.g. the legend's meanings legitimately
// differ; only the role + glyph are shared truth).
//
// COVERAGE (honest scope — subset-parity, projection ⊆ native):
//   - COVERED: for every column/row PRESENT in the shared projection, all three
//     surfaces (Elixir view / web / this TUI) agree on label + count + ordered
//     card titles + glyph-role. The label check is EXACT: a lane header renders
//     `glyph Label␣␣count`, so the projection label must appear as that delimited
//     field (single space before, 2+ spaces after) — a superstring rename
//     (`Blocked`→`Blockedz`) or a prefix rename fails, matching the Elixir
//     exact-span and web exact-equality legs.
//   - NOT COVERED (known divergences, FILED not fixed):
//     (a) task-board `open`-task DROP — the Elixir 4-col omit-empty view drops
//         `open` tasks the web 5-col view keeps. A ⊆-projection structurally
//         cannot catch an omission, so the task-board fixture omits `open`;
//         owned by bug-taskboard-drops-open-tasks (carries the open-inclusive
//         cross-surface test).
//     (b) status/label PROSE differs (Elixir "in progress"/"cancelled" vs Go
//         "progress"/"cancel"). The projection shares role + glyph, NOT meaning
//         text; owned by au-w5-status-prose-parity. Board column LABELS are
//         likewise "two copies agree" (gen `@board_columns` + components.ex,
//         tied by this realization test), not a single manifest source — folded
//         into au-w5-status-prose-parity.

// labelSpanRe matches a projection column label as the EXACT delimited header
// field the TUI emits: `glyph Label␣␣count`. The label is bounded by a single
// space (the glyph separator; or line start) before and 2+ spaces (the count
// separator) after — so BOTH a superstring rename (append or prepend) and a
// substring fail, giving this leg the same strictness as the Elixir exact-span
// and web exact-equality legs (a bare strings.Contains let `Blocked`→`Blockedz`
// wrongly pass).
func labelSpanRe(label string) *regexp.Regexp {
	return regexp.MustCompile(`(?:^| )` + regexp.QuoteMeta(label) + ` {2,}`)
}

type componentGolden struct {
	Type     string          `json:"type"`
	Input    json.RawMessage `json:"input"`
	Expected json.RawMessage `json:"expected"`
}

type boardProjection struct {
	ContainerRole string `json:"container_role"`
	Columns       []struct {
		Role      string `json:"role"`
		Label     string `json:"label"`
		GlyphRole string `json:"glyph_role"`
		Count     int    `json:"count"`
		Cards     []struct {
			Title string `json:"title"`
		} `json:"cards"`
	} `json:"columns"`
}

type legendProjection struct {
	ContainerRole string `json:"container_role"`
	Rows          []struct {
		Role      string `json:"role"`
		GlyphRole string `json:"glyph_role"`
		Glyph     string `json:"glyph"`
		Spinner   bool   `json:"spinner"`
	} `json:"rows"`
}

func loadComponentGolden(t *testing.T, typ string) componentGolden {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", typ+".golden.json"))
	if err != nil {
		t.Fatalf("read %s golden fixture: %v", typ, err)
	}
	var fx componentGolden
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode %s golden fixture: %v", typ, err)
	}
	if fx.Type != typ {
		t.Fatalf("fixture type = %q, want %q — mirror drift?", fx.Type, typ)
	}
	if len(fx.Input) == 0 || len(fx.Expected) == 0 {
		t.Fatalf("fixture floor: %s missing input/expected", typ)
	}
	return fx
}

// renderComponent wraps the fixture's authored `input` block VERBATIM in the
// single-block doc shape a paper serves and renders it through the real embed
// seam (Decode -> RenderDoc, Width 200, NoColor, ansi.Strip).
func renderComponent(t *testing.T, input json.RawMessage) string {
	t.Helper()
	reg := testRegistry()
	blocks, err := Decode([]byte("[" + string(input) + "]"))
	if err != nil {
		t.Fatalf("decode component block: %v", err)
	}
	ctx := RenderCtx{Width: 200, Theme: DarkTheme(), Profile: NoColor}
	out := ansi.Strip(reg.RenderDoc(blocks, ctx))
	if strings.Contains(out, "unknown block") {
		t.Fatalf("component fell through to the unknown-block box:\n%s", out)
	}
	return out
}

// TestTaskBoardGoldenParity proves the TUI task-board renderer realizes the
// projection: every column label and every card title the Elixir source-of-truth
// produced survives to the terminal render, and the fixture's per-column card
// list is self-consistent with its count.
func TestTaskBoardGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "task-board")
	var proj boardProjection
	if err := json.Unmarshal(fx.Expected, &proj); err != nil {
		t.Fatalf("decode board projection: %v", err)
	}
	if proj.ContainerRole != "board" {
		t.Fatalf("container_role = %q, want board", proj.ContainerRole)
	}
	if len(proj.Columns) < 3 {
		t.Fatalf("projection floor: %d columns, want >= 3", len(proj.Columns))
	}

	out := renderComponent(t, fx.Input)

	for _, col := range proj.Columns {
		if !labelSpanRe(col.Label).MatchString(out) {
			t.Errorf("column label %q missing (as an exact `glyph Label␣␣count` header field) from render:\n%s", col.Label, out)
		}
		if col.Count != len(col.Cards) {
			t.Errorf("fixture inconsistent: column %q count=%d but %d cards", col.Role, col.Count, len(col.Cards))
		}
		for _, card := range col.Cards {
			if !strings.Contains(out, card.Title) {
				t.Errorf("card title %q (column %q) missing from render:\n%s", card.Title, col.Role, out)
			}
		}
	}
}

// TestStatusLegendGoldenParity proves the TUI status-legend renderer realizes the
// projection: one rung per projection row (in manifest order), each role name
// present, and the SHARED static glyph char (the Elixir-manifest truth) rendered
// for every non-spinner role. The spinner role's glyph is surface-local (empty in
// the HTML+CSS, a steady Braille frame in the terminal), so only its role — not a
// glyph char — is asserted, exactly what the structural contract shares.
func TestStatusLegendGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "status-legend")
	var proj legendProjection
	if err := json.Unmarshal(fx.Expected, &proj); err != nil {
		t.Fatalf("decode legend projection: %v", err)
	}
	if proj.ContainerRole != "legend" {
		t.Fatalf("container_role = %q, want legend", proj.ContainerRole)
	}
	if len(proj.Rows) != 6 {
		t.Fatalf("projection floor: %d rungs, want 6 (the white ladder)", len(proj.Rows))
	}

	out := renderComponent(t, fx.Input)

	// One rendered line per rung (the legend stacks one rung per line).
	lines := 0
	for _, ln := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if strings.TrimSpace(ln) != "" {
			lines++
		}
	}
	if lines != len(proj.Rows) {
		t.Errorf("legend rendered %d non-empty lines, want %d rungs:\n%s", lines, len(proj.Rows), out)
	}

	for _, row := range proj.Rows {
		if !strings.Contains(out, row.Role) {
			t.Errorf("rung role %q missing from render:\n%s", row.Role, out)
		}
		if !row.Spinner {
			if !strings.Contains(out, row.Glyph) {
				t.Errorf("static glyph %q for role %q missing from render:\n%s", row.Glyph, row.Role, out)
			}
		}
	}
}
