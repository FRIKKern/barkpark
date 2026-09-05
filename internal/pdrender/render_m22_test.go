package pdrender

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// renderM22 renders the M22 roadmap-v2 milestone-trio fixture at one width under
// one colour profile, pinning BOTH ctx.Profile and the process-global lipgloss
// profile so a colour-capable render emits real SGR. Returns the RAW output with
// escapes intact; callers strip to compare.
func renderM22(t *testing.T, width int, p Profile) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m22.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(lipglossProfileFor(p))
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })
	reg := DefaultRegistry(DarkTheme())
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: p}
	out := reg.RenderDoc(blocks, ctx)
	// Shared blind-spot guard (unknown_block_guard_test.go).
	assertNoUnknownBlock(t, "sample_m22.json", ansi.Strip(out))
	return out
}

// TestGoldenM22 is the roadmap-v2 glyph layer: date-derived lanes off a block
// [start,end] span, distributed-rounding month ┊ ticks, ▓done/░planned fill,
// ◆milestones, ◇notes and a ┃today marker — plus a literal-pct fallback lane
// (`Legacy plan`) proving the pre-v2 path still lands identical cell math. The
// NoColor render is byte-stable at every golden width; regenerate with -update.
func TestGoldenM22(t *testing.T) {
	for _, w := range goldenWidths {
		w := w
		t.Run("sample_m22_w"+itoa(w), func(t *testing.T) {
			got := ansi.Strip(renderM22(t, w, NoColor))
			goldenPath := filepath.Join("testdata", "golden", "sample_m22_w"+itoa(w)+".txt")
			if *update {
				if err := os.MkdirAll(filepath.Dir(goldenPath), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
					t.Fatal(err)
				}
				return
			}
			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden (run with -update to create): %v", err)
			}
			if got != string(want) {
				t.Errorf("M22 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestRoadmapV22StripComplete is the acceptance proof that the roadmap-v2 glyph
// layer is a COMPLETE artifact at all three profiles: stripping the ANSI256 and
// TrueColor renders yields byte-for-byte the NoColor render. Every datum — done
// vs planned fill, milestones, notes, today, month ticks — lives in the glyph
// geometry; colour is pure reinforcement (the detail-ceiling strip law).
func TestRoadmapV22StripComplete(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "sample_m22.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	reg := DefaultRegistry(DarkTheme())
	assertStripComplete(t, "roadmap_v2_sample_m22", func(w int, p Profile) string {
		return reg.RenderDoc(blocks, RenderCtx{Width: w, Theme: DarkTheme(), Profile: p})
	})
}

// TestDistributeSegments pins the drift-free month-tick contract: the parts sum
// to EXACTLY the track (never over/undershoot) and differ by at most one cell,
// across a matrix of tracks and segment counts including n > total.
func TestDistributeSegments(t *testing.T) {
	cases := []struct{ total, n int }{
		{40, 6}, {60, 6}, {80, 6}, {120, 6}, {66, 6},
		{10, 3}, {7, 4}, {3, 6}, {1, 1}, {100, 7}, {13, 5},
	}
	for _, c := range cases {
		sizes := distributeSegments(c.total, c.n)
		if len(sizes) != c.n {
			t.Fatalf("distributeSegments(%d,%d): got %d segments, want %d", c.total, c.n, len(sizes), c.n)
		}
		sum, min, max := 0, sizes[0], sizes[0]
		for _, s := range sizes {
			sum += s
			if s < min {
				min = s
			}
			if s > max {
				max = s
			}
			if s < 0 {
				t.Errorf("distributeSegments(%d,%d): negative segment %d in %v", c.total, c.n, s, sizes)
			}
		}
		if sum != c.total {
			t.Errorf("distributeSegments(%d,%d): sum %d != total %d (drift!) %v", c.total, c.n, sum, c.total, sizes)
		}
		if max-min > 1 {
			t.Errorf("distributeSegments(%d,%d): spread max-min=%d > 1 (uneven) %v", c.total, c.n, max-min, sizes)
		}
	}
	// Degenerate inputs return no segments (never panic).
	if got := distributeSegments(0, 4); got != nil {
		t.Errorf("distributeSegments(0,4) = %v, want nil", got)
	}
	if got := distributeSegments(10, 0); got != nil {
		t.Errorf("distributeSegments(10,0) = %v, want nil", got)
	}
}

// TestRoadmapLeftWidthPreSpanStart pins the clamped-left subtraction in
// roadmapLeftWidth (24a6779d): a row whose start PREDATES the block span clamps
// left to 0 and its bar still ENDS at the row-end's true position — the width is
// dateToPct(rowEnd), never inflated by the out-of-span overshoot (subtracting
// the raw negative left would stretch the bar ~34pct past the row's end here).
func TestRoadmapLeftWidthPreSpanStart(t *testing.T) {
	span := func(s string) time.Time {
		d, ok := parseISODate(s)
		if !ok {
			t.Fatalf("parseISODate(%q) failed", s)
		}
		return d
	}
	start, end := span("2026-01-01"), span("2026-07-01")

	// Pre-span start: 2025-11-01 → raw pct ≈ -33.7, clamps to the left edge.
	row := map[string]any{"start": "2025-11-01", "end": "2026-03-01"}
	left, width := roadmapLeftWidth(row, start, end, true)
	if left != 0 {
		t.Errorf("pre-span row start: left = %v, want 0 (clamped to track edge)", left)
	}
	wantWidth := dateToPct(span("2026-03-01"), start, end) // ≈ 32.6 — the row-end's true position
	if width != wantWidth {
		t.Errorf("pre-span row start: width = %v, want %v (bar must end at the row-end's position, not stretch by the overshoot)", width, wantWidth)
	}

	// In-span row: clampPct is the identity, so both subtractions agree — the
	// clamped-left fix is byte-neutral for every in-span lane.
	inRow := map[string]any{"start": "2026-02-01", "end": "2026-04-01"}
	inLeft, inWidth := roadmapLeftWidth(inRow, start, end, true)
	wantLeft := dateToPct(span("2026-02-01"), start, end)
	wantIn := dateToPct(span("2026-04-01"), start, end) - wantLeft
	if inLeft != wantLeft || inWidth != wantIn {
		t.Errorf("in-span row: (left,width) = (%v,%v), want (%v,%v)", inLeft, inWidth, wantLeft, wantIn)
	}
}

// TestRoadmapCellPrecedence pins the per-cell glyph precedence ┃ > ◆ > ◇ > ▓/░ >
// ┊ > · by colliding every marker on a single cell and asserting the winner. The
// stripped glyph at the collision index is the higher-precedence one each time.
func TestRoadmapCellPrecedence(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	// A lane fully filled (done → ▓), a note+milestone+tick all at cell 2, today
	// layered on in the strongest case.
	base := laneMarks{fillGlyph: "▓", fillStyle: statusGlyphStyle(ctx.Theme, "done"), start: 0, fill: 5}
	track := 5
	ticks := map[int]bool{2: true}

	glyphAt := func(m laneMarks, todayCell int) string {
		out := ansi.Strip(renderTrack(ctx, m, track, todayCell, ticks))
		r := []rune(out)
		if len(r) <= 2 {
			t.Fatalf("track too short: %q", out)
		}
		return string(r[2])
	}

	// tick(┊) loses to fill(▓): cell 2 is under the fill run.
	if g := glyphAt(base, -1); g != "▓" {
		t.Errorf("fill > tick: cell 2 = %q, want ▓", g)
	}
	// note(◇) beats fill.
	m := base
	m.note = 2
	if g := glyphAt(m, -1); g != "◇" {
		t.Errorf("note > fill: cell 2 = %q, want ◇", g)
	}
	// milestone(◆) beats note.
	m.milestone = 2
	if g := glyphAt(m, -1); g != "◆" {
		t.Errorf("milestone > note: cell 2 = %q, want ◆", g)
	}
	// today(┃) beats milestone.
	if g := glyphAt(m, 2); g != "┃" {
		t.Errorf("today > milestone: cell 2 = %q, want ┃", g)
	}

	// tick(┊) beats empty(·): an unfilled lane with a tick at cell 2.
	empty := laneMarks{fillGlyph: "░", fillStyle: statusGlyphStyle(ctx.Theme, "ready"), start: 0, fill: 0, milestone: -1, note: -1}
	if g := glyphAt(empty, -1); g != "┊" {
		t.Errorf("tick > empty: cell 2 = %q, want ┊", g)
	}
}
