package pdrender

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
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
//   - COVERED since bug-taskboard-drops-open-tasks: the task-board fixture now
//     INCLUDES an `open` row and the Elixir View + this Go pdrender both grew an
//     `open` column, so a populated `open` bucket realizes on every surface (the
//     drop is fixed, not just filed). Empty-column policy (web keep-empty vs
//     View/TUI omit-empty) stays a SUPERSET difference the ⊆-projection does not
//     police.
//   - COVERED since au-w5-status-prose-parity: the status LABEL prose is ONE
//     manifest source (design/status-manifest.json roles[].label, inlined here as
//     roleLabel and byte-checked by scripts/status-manifest-check.sh Part 4). The
//     legend projection asserts the canonical label TEXT (progress→"in progress",
//     cancel→"cancelled") and this TUI leg RENDERS it. Board column LABELS are the
//     fold too — boardColumns roles + a derived boardLabel (sentence-cased
//     canonical label), not a second hardcoded copy. Legend MEANING (roleMeaning)
//     is an Elixir/TUI superset the web reader does not render.
//   - NOT COVERED (known divergences, FILED not fixed): card slot order + tone +
//     media fast-path (au-w5-card-slot-parity).

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
		Label     string `json:"label"`
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
	assertNoUnknownBlock(t, "component golden", out)
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
	if len(proj.Rows) != 8 {
		t.Fatalf("projection floor: %d rungs, want 8 (the white ladder + the two thought states)", len(proj.Rows))
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
		// GRADUATED (au-w5-status-prose-parity): the canonical LABEL text is the
		// shared truth the TUI renders (progress→"in progress", cancel→"cancelled"),
		// not the raw role slug — a wrong label render reds this leg.
		if !strings.Contains(out, row.Label) {
			t.Errorf("rung label %q missing from render:\n%s", row.Label, out)
		}
		if !row.Spinner {
			if !strings.Contains(out, row.Glyph) {
				t.Errorf("static glyph %q for role %q missing from render:\n%s", row.Glyph, row.Role, out)
			}
		}
	}
}

// ── S2 legs: the TUI renderer realizes each projection ───────────────────────
//
// Each leg renders the fixture's authored `input` through the real embed seam and
// asserts the TUI output realizes the SHARED projection at the strictness the
// terminal surface can hold (stripped-ANSI substring; role/tone colour that the
// terminal expresses as style — not text — is asserted by the web/Elixir legs).

// mustContain fails when needle is absent from the render.
func mustContain(t *testing.T, out, needle, what string) {
	t.Helper()
	if needle == "" {
		return
	}
	if !strings.Contains(out, needle) {
		t.Errorf("%s %q missing from render:\n%s", what, needle, out)
	}
}

func mustNotContain(t *testing.T, out, needle, what string) {
	t.Helper()
	if strings.Contains(out, needle) {
		t.Errorf("%s %q leaked into render:\n%s", what, needle, out)
	}
}

// TestStageSourceCoercion is the bug-fix regression for au-w5-pipeline-source-parity:
// the old code stringified `source` via attrStr→toStr, so a boolean `true` leaked a
// literal "source: true" line and `false` leaked "source: false". The RATIFIED model
// type-switches the RAW attr BEFORE stringifying: true → the ◆ ORIGIN eyebrow (never
// a literal "true"); a non-empty string → the "source: <text>" provenance line;
// false/absent → nothing. Each assertion reds if reverted to the toStr path.
func TestStageSourceCoercion(t *testing.T) {
	origin := renderComponent(t, json.RawMessage(`{"type":"stage","title":"Ingest","source":true}`))
	mustContain(t, origin, "◆ ORIGIN", "stage source:true origin marker")
	mustNotContain(t, origin, "source: true", "stage source:true literal leak")

	prov := renderComponent(t, json.RawMessage(`{"type":"stage","title":"Ingest","source":"queue.ex:42"}`))
	mustContain(t, prov, "source: queue.ex:42", "stage source:string provenance line")
	mustNotContain(t, prov, "◆ ORIGIN", "stage source:string false origin")

	no := renderComponent(t, json.RawMessage(`{"type":"stage","title":"Ingest","source":false}`))
	mustNotContain(t, no, "source: false", "stage source:false literal leak")
	mustNotContain(t, no, "◆ ORIGIN", "stage source:false origin")

	absent := renderComponent(t, json.RawMessage(`{"type":"stage","title":"Ingest"}`))
	mustNotContain(t, absent, "source:", "stage source-absent line")
	mustNotContain(t, absent, "◆ ORIGIN", "stage source-absent origin")
}

// unmarshalExpected decodes the fixture's expected projection into dst.
func unmarshalExpected(t *testing.T, fx componentGolden, dst any) {
	t.Helper()
	if err := json.Unmarshal(fx.Expected, dst); err != nil {
		t.Fatalf("decode projection: %v", err)
	}
}

func TestNotesGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "notes")
	var proj struct {
		Rows []struct{ Label, Lead, Text string } `json:"rows"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Rows) < 2 {
		t.Fatalf("projection floor: %d rows, want >= 2", len(proj.Rows))
	}
	out := renderComponent(t, fx.Input)
	for _, r := range proj.Rows {
		mustContain(t, out, r.Label, "note label")
		mustContain(t, out, r.Lead, "note lead")
		mustContain(t, out, r.Text, "note text")
	}
}

func TestNoteGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "note")
	var proj struct{ Label, Lead, Text string }
	unmarshalExpected(t, fx, &proj)
	out := renderComponent(t, fx.Input)
	mustContain(t, out, proj.Label, "note label")
	mustContain(t, out, proj.Lead, "note lead")
	mustContain(t, out, proj.Text, "note text")
}

func TestCardsGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "cards")
	var proj struct {
		Cards []struct{ Title, Text, Tone string } `json:"cards"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Cards) < 2 {
		t.Fatalf("projection floor: %d cards, want >= 2", len(proj.Cards))
	}
	out := renderComponent(t, fx.Input)
	for _, c := range proj.Cards {
		mustContain(t, out, c.Title, "card title")
		mustContain(t, out, c.Text, "card text")
	}
}

// TestCardGoldenParity proves the TUI card renderer realizes the MODEL-B
// projection (au-w5-card-slot-parity GRADUATED): the card's PRESENT slots render
// in the projected order (media·title·body·action), the media image fast-paths to
// the 🖼 image box (not the unknown-block degrade), and the action button renders.
// The `tone` accent is a border COLOUR the terminal expresses as style — stripped
// under NoColor — so (like the roadmap lane bar) the coloured Elixir/web legs own
// the tone assertion, not this TUI leg; the ORDER + image drops are what red here.
func TestCardGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "card")
	var proj struct {
		Slots         []string `json:"slots"`
		Tone          string   `json:"tone"`
		MediaFastpath bool     `json:"media_fastpath"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Slots) != 4 {
		t.Fatalf("projection floor: %d slots, want 4 (the model-B media·title·body·action)", len(proj.Slots))
	}

	// Authored slot render markers, DERIVED from the fixture input (never hand-typed).
	var in struct {
		Slots struct {
			Media []struct {
				Alt string `json:"alt"`
			} `json:"media"`
			Title []struct {
				Text string `json:"text"`
			} `json:"title"`
			Body []struct {
				Content []struct {
					Value string `json:"value"`
				} `json:"content"`
			} `json:"body"`
			Action []struct {
				Label string `json:"label"`
			} `json:"action"`
		} `json:"slots"`
	}
	if err := json.Unmarshal(fx.Input, &in); err != nil {
		t.Fatalf("decode card input: %v", err)
	}
	marker := map[string]string{
		"media":  in.Slots.Media[0].Alt,
		"title":  in.Slots.Title[0].Text,
		"body":   in.Slots.Body[0].Content[0].Value,
		"action": in.Slots.Action[0].Label,
	}

	out := renderComponent(t, fx.Input)

	// Each PROJECTED slot's authored text renders, IN the projection's slot ORDER —
	// a reorder or a dropped slot in cardRenderer reds this ordered-spine check.
	prev := -1
	for _, slot := range proj.Slots {
		m := marker[slot]
		mustContain(t, out, m, "card slot "+slot)
		if idx := strings.Index(out, m); idx >= 0 {
			if idx < prev {
				t.Errorf("card slot %q rendered out of model-B order (idx %d < %d):\n%s", slot, idx, prev, out)
			}
			prev = idx
		}
	}

	// media fast-path: the image media child renders as the 🖼 image box (a
	// dropped/degraded image loses the glyph and reds).
	if proj.MediaFastpath {
		mustContain(t, out, "🖼", "card media image fast-path")
	}
}

func TestPipelineGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "pipeline")
	var proj struct {
		Nodes []struct {
			Kind, Title, Detail string
			SourceRole          string `json:"source_role"`
			SourceText          string `json:"source_text"`
		} `json:"nodes"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Nodes) < 2 {
		t.Fatalf("projection floor: %d nodes, want >= 2", len(proj.Nodes))
	}
	out := renderComponent(t, fx.Input)
	sawOrigin, sawProvenance := false, false
	for _, n := range proj.Nodes {
		// The stage renderer UPPERCASES the kind kicker.
		mustContain(t, out, strings.ToUpper(n.Kind), "pipeline node kind")
		mustContain(t, out, n.Title, "pipeline node title")
		mustContain(t, out, n.Detail, "pipeline node detail")

		// source_role realizes: origin → the ◆ ORIGIN marker; provenance → the
		// "source: <text>" line (a render tamper reds this leg).
		switch n.SourceRole {
		case "origin":
			sawOrigin = true
			mustContain(t, out, "◆ ORIGIN", "pipeline origin marker")
		case "provenance":
			sawProvenance = true
			mustContain(t, out, "source: "+n.SourceText, "pipeline provenance line")
		}
	}
	// non-vacuous: the fixture must exercise BOTH coercion branches.
	if !sawOrigin || !sawProvenance {
		t.Fatalf("fixture must carry an origin AND a provenance node (origin=%v provenance=%v)", sawOrigin, sawProvenance)
	}
}

func TestStageGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "stage")
	var proj struct {
		Kind, Title, Detail string
		SourceRole          string `json:"source_role"`
		SourceText          string `json:"source_text"`
	}
	unmarshalExpected(t, fx, &proj)
	out := renderComponent(t, fx.Input)
	mustContain(t, out, strings.ToUpper(proj.Kind), "stage kind")
	mustContain(t, out, proj.Title, "stage title")
	mustContain(t, out, proj.Detail, "stage detail")
	switch proj.SourceRole {
	case "origin":
		mustContain(t, out, "◆ ORIGIN", "stage origin marker")
	case "provenance":
		mustContain(t, out, "source: "+proj.SourceText, "stage provenance line")
	}
}

func TestTaskDetailGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "task-detail")
	var proj struct {
		Title    string `json:"title"`
		Sections []string
		Timeline []struct {
			Role      string `json:"role"`
			GlyphRole string `json:"glyph_role"`
			Label     string `json:"label"`
		} `json:"timeline"`
		Criteria struct {
			Met, Total int
		} `json:"criteria"`
	}
	unmarshalExpected(t, fx, &proj)
	out := renderComponent(t, fx.Input)
	mustContain(t, out, proj.Title, "task-detail title")
	// The criteria rollup label is shared verbatim across surfaces.
	if proj.Criteria.Total > 0 {
		mustContain(t, out, fmt.Sprintf("Criteria · %d/%d", proj.Criteria.Met, proj.Criteria.Total), "criteria rollup")
	}
	// Timeline is now COVERED (au-w5-task-detail-timeline-parity): every ordered
	// cell's label survives to the terminal render (the cell's role is a glyph the
	// Elixir/web legs own; this TUI leg asserts the shared label text).
	if len(proj.Timeline) == 0 {
		t.Fatalf("projection floor: task-detail fixture carries no timeline")
	}
	for _, seg := range proj.Timeline {
		mustContain(t, out, seg.Label, "task-detail timeline label")
	}
}

func TestRoadmapGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "roadmap")
	var proj struct {
		Lanes []struct {
			Title string `json:"title"`
			Role  string `json:"role"`
			Phase bool   `json:"phase"`
		} `json:"lanes"`
		Scale []string `json:"scale"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Lanes) < 2 {
		t.Fatalf("projection floor: %d lanes, want >= 2", len(proj.Lanes))
	}
	out := renderComponent(t, fx.Input)
	for _, c := range proj.Scale {
		mustContain(t, out, c, "roadmap scale cell")
	}
	// Lane label survives to the render; the lane's ROLE is a bar colour (not
	// text) so the web/Elixir legs own the role assertion, not this TUI leg.
	for _, ln := range proj.Lanes {
		mustContain(t, out, ln.Title, "roadmap lane title")
	}
}

func TestColumnsGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "columns")
	var proj struct {
		Columns [][]string `json:"columns"`
	}
	unmarshalExpected(t, fx, &proj)
	if len(proj.Columns) < 2 {
		t.Fatalf("projection floor: %d columns, want >= 2", len(proj.Columns))
	}
	out := renderComponent(t, fx.Input)
	// The nested child prose survives the container recursion (each column's
	// paragraph carries distinct text in the fixture input).
	mustContain(t, out, "Left column body.", "columns left child")
	mustContain(t, out, "Right column body.", "columns right child")
}

func TestTerminalGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "terminal")
	var proj struct {
		Title    string   `json:"title"`
		Live     bool     `json:"live"`
		Footer   string   `json:"footer"`
		Children []string `json:"children"`
	}
	unmarshalExpected(t, fx, &proj)
	out := renderComponent(t, fx.Input)
	mustContain(t, out, proj.Title, "terminal title")
	mustContain(t, out, proj.Footer, "terminal footer")
	if proj.Live {
		mustContain(t, out, "live", "terminal live chip")
	}
	// The nested child block renders inside the frame.
	mustContain(t, out, "Inside the frame.", "terminal child")
}

// TestSectionGoldenParity proves the TUI grid-section renderer (sectionRenderer.
// gridBody) realizes the projection's SHARED facts at the strictness the terminal
// can hold: every cell's child prose survives to the render, AND the cells render
// in CSS-`order` sequence (a stable sort — the reader emits `order:`, so a terminal
// reorder is parity-correct). The AUTHORED `span` integer is NOT asserted here — the
// TUI CLAMPS span to the track budget and expresses width as geometry, not text (a
// carve-out analogous to the roadmap lane-bar / card-tone COLOUR carve-outs above:
// the Elixir/web legs own the unclamped span assertion). A drop of the order-honoring
// reorder reds this leg (the fixture's order:-1 cell hoists to the front).
func TestSectionGoldenParity(t *testing.T) {
	fx := loadComponentGolden(t, "section")
	var proj struct {
		ContainerRole string `json:"container_role"`
		Mode          string `json:"mode"`
		Tracks        int    `json:"tracks"`
		Gap           string `json:"gap"`
		Cells         []struct {
			Span  *int   `json:"span"`
			Order *int   `json:"order"`
			Type  string `json:"type"`
		} `json:"cells"`
	}
	unmarshalExpected(t, fx, &proj)
	if proj.ContainerRole != "section" {
		t.Fatalf("container_role = %q, want section", proj.ContainerRole)
	}
	if proj.Mode != "grid" {
		t.Fatalf("mode = %q, want grid", proj.Mode)
	}
	if proj.Tracks < 2 {
		t.Fatalf("projection floor: tracks=%d, want >= 2 (a grid needs multiple tracks)", proj.Tracks)
	}
	if len(proj.Cells) < 2 {
		t.Fatalf("projection floor: %d cells, want >= 2", len(proj.Cells))
	}

	// Each cell's authored child prose (the card's title), aligned by index with the
	// projection cells (cell[i] ↔ input.blocks[i]) — read from the input, never hand-typed.
	var in struct {
		Blocks []struct {
			Slots struct {
				Title []struct {
					Text string `json:"text"`
				} `json:"title"`
			} `json:"slots"`
		} `json:"blocks"`
	}
	if err := json.Unmarshal(fx.Input, &in); err != nil {
		t.Fatalf("decode section input: %v", err)
	}
	if len(in.Blocks) != len(proj.Cells) {
		t.Fatalf("fixture inconsistent: %d input blocks but %d projection cells", len(in.Blocks), len(proj.Cells))
	}

	out := renderComponent(t, fx.Input)

	// Child prose: every cell's title survives the grid recursion.
	type cell struct {
		prose string
		order int
	}
	cells := make([]cell, len(proj.Cells))
	sawOrderHoist := false
	for i, c := range proj.Cells {
		if len(in.Blocks[i].Slots.Title) == 0 {
			t.Fatalf("fixture floor: block %d carries no title prose", i)
		}
		prose := in.Blocks[i].Slots.Title[0].Text
		mustContain(t, out, prose, "section cell prose")
		ord := 0
		if c.Order != nil {
			ord = *c.Order
			sawOrderHoist = true
		}
		cells[i] = cell{prose: prose, order: ord}
	}
	// Non-vacuous: the fixture MUST carry an explicit `order` cell to prove the reorder.
	if !sawOrderHoist {
		t.Fatalf("fixture lost its order cell — the CSS-order reorder assertion would be vacuous")
	}

	// ORDERING: the cells render in CSS-`order` sequence (stable — mirrors the
	// gridBody `sort.SliceStable(cellOrder)`). Build the expected rendered order and
	// assert each prose appears at a strictly increasing offset. A reader that
	// IGNORED order would render authored order and red here (the order:-1 cell moves).
	expected := make([]cell, len(cells))
	copy(expected, cells)
	sort.SliceStable(expected, func(i, j int) bool { return expected[i].order < expected[j].order })

	prev := -1
	for _, c := range expected {
		idx := strings.Index(out, c.prose)
		if idx < 0 {
			t.Errorf("section cell prose %q missing from render:\n%s", c.prose, out)
			continue
		}
		if idx <= prev {
			t.Errorf("section cell %q rendered out of CSS-order sequence (idx %d <= %d):\n%s", c.prose, idx, prev, out)
		}
		prev = idx
	}
}
