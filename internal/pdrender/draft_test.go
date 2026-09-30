package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// THE DRAFT MARKER on the Go paper reader (task-3fe42aeef86645a9, PDS-D749): a
// task-snapshot row carrying draft:true paints `DRAFT` before its title on the
// task-list (flat + tree), task-board and roadmap (placed + unplaced) readers;
// a row without the key renders byte-identical to the same row pre-marker.

func draftBlock(typ string, extra map[string]any, rows ...map[string]any) Block {
	snap := make([]any, len(rows))
	for i, r := range rows {
		snap[i] = r
	}
	attrs := map[string]any{"type": typ, "snapshot": snap}
	for k, v := range extra {
		attrs[k] = v
	}
	return Block{Type: typ, Attrs: attrs}
}

func draftRows() (draft, published map[string]any) {
	return map[string]any{"title": "Unpublished row", "status": "open", "priority": "2", "draft": true},
		map[string]any{"title": "Published row", "status": "open", "priority": "2"}
}

// draftLineWith returns the first rendered line containing needle ("" when none).
func draftLineWith(out, needle string) string {
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ln, needle) {
			return ln
		}
	}
	return ""
}

func TestDraftMarkerRidesTheTitleOnEveryTaskReader(t *testing.T) {
	reg := testRegistry()
	d, p := draftRows()
	cases := []struct {
		name string
		b    Block
	}{
		{"task-list", draftBlock("task-list", nil, d, p)},
		{"tasks", draftBlock("tasks", nil, d, p)},
		{"task-list tree", draftBlock("task-list", map[string]any{"layout": map[string]any{"mode": "tree"}}, d, p)},
		{"task-board", draftBlock("task-board", nil, d, p)},
		{"roadmap placed", draftBlock("roadmap", nil,
			map[string]any{"title": "Unpublished row", "status": "open", "left": 0.0, "width": 40.0, "draft": true},
			map[string]any{"title": "Published row", "status": "open", "left": 40.0, "width": 40.0})},
		{"roadmap unplaced", draftBlock("roadmap", map[string]any{"query": map[string]any{"type": "task"}}, d, p)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := renderBlock(reg, tc.b, 120)
			if !strings.Contains(out, "DRAFT Unpublished row") {
				t.Errorf("draft row renders without `DRAFT <title>`:\n%s", out)
			}
			if got := strings.Count(out, "DRAFT"); got != 1 {
				t.Errorf("render carries %d DRAFT markers, want exactly 1:\n%s", got, out)
			}
			if strings.Contains(draftLineWith(out, "Published row"), "DRAFT") {
				t.Errorf("published row wrongly carries the DRAFT marker:\n%s", out)
			}
		})
	}
}

// A row without the key (or with a non-boolean-true value) renders byte-identical
// to the same row with no draft key at all — draft_html/1's `== true` contract.
func TestDraftMarkerAbsentKeyIsByteIdentical(t *testing.T) {
	reg := testRegistry()
	for _, typ := range []string{"task-list", "task-board", "roadmap"} {
		base := map[string]any{"title": "Row", "status": "ready", "priority": "1", "left": 10.0, "width": 30.0}
		want := renderBlock(reg, draftBlock(typ, nil, base), 80)
		for _, v := range []any{false, "true", 1.0, nil} {
			r := map[string]any{"title": "Row", "status": "ready", "priority": "1", "left": 10.0, "width": 30.0, "draft": v}
			if got := renderBlock(reg, draftBlock(typ, nil, r), 80); got != want {
				t.Errorf("%s: draft=%#v changed the render:\n got: %q\nwant: %q", typ, v, got, want)
			}
		}
	}
}

// Narrow widths: the marker rides the title, so it survives where the trailing
// meta sheds, and fixed-width label cells keep their exact visible width.
func TestDraftMarkerSurvivesNarrowWidths(t *testing.T) {
	reg := testRegistry()
	d, p := draftRows()
	d["worker"], d["criteria"] = "lane-worker", map[string]any{"met": 1.0, "total": 3.0}
	for _, w := range []int{24, 32, 40} {
		for _, b := range []Block{
			draftBlock("task-list", nil, d, p),
			draftBlock("task-list", map[string]any{"layout": map[string]any{"mode": "tree"}}, d, p),
			draftBlock("task-board", nil, d, p),
			draftBlock("roadmap", nil,
				map[string]any{"title": "Unpublished row", "status": "open", "left": 0.0, "width": 40.0, "draft": true},
				map[string]any{"title": "Published row", "status": "open", "left": 40.0, "width": 40.0}),
		} {
			out := renderBlock(reg, b, w)
			if !strings.Contains(out, "DRAFT") {
				t.Errorf("%s at w=%d: the DRAFT marker vanished:\n%s", b.Type, w, out)
			}
			for _, ln := range strings.Split(out, "\n") {
				if lw := ansi.StringWidth(ln); lw > w {
					t.Errorf("%s at w=%d: line overflows (%d cols): %q", b.Type, w, lw, ln)
				}
			}
		}
	}
}

// draftFitLabel: at a cell too narrow for `DRAFT ` whole, the clipped remnant is
// still painted (the marker clips, it never disappears), and the cell's visible
// width is exact at every budget.
func TestDraftFitLabelExactWidth(t *testing.T) {
	d, p := draftRows()
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	for w := 2; w <= 30; w++ {
		for _, r := range []map[string]any{d, p} {
			got := draftFitLabel(r, ctx, attrStr(r, "title"), w, ctx.Theme.Body)
			if gw := ansi.StringWidth(got); gw != w {
				t.Errorf("draftFitLabel(draft=%v, w=%d) width = %d, want %d: %q", r["draft"], w, gw, w, ansi.Strip(got))
			}
		}
		if s := ansi.Strip(draftFitLabel(d, ctx, "Unpublished row", w, ctx.Theme.Body)); !strings.HasPrefix(s, "D") {
			t.Errorf("draftFitLabel(w=%d) lost the marker's head: %q", w, s)
		}
	}
}
