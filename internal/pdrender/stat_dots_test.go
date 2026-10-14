package pdrender

// stat_dots_test.go — the TUI leg of stat trial dots (pe-bl-stat-tile-dots).
//
// data_viz.ex draws `dots: {on, of}` as an accessible dot array on web and as
// "●●○○○ 2/5" text in email; the terminal draws the same text row under the
// value. Drop the statDots call from statCell and TestStatDotsRow reds.

import (
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func plainCell(m map[string]any, width int) []string {
	ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
	lines := statCell(m, ctx)
	for i, l := range lines {
		lines[i] = ansi.Strip(l)
	}
	return lines
}

func TestStatDotsRow(t *testing.T) {
	lines := plainCell(map[string]any{"value": "2", "label": "trials", "dots": map[string]any{"on": 2.0, "of": 10.0}}, 40)
	want := []string{"2", "●●○○○○○○○○ 2/10", "trials"}
	if !reflect.DeepEqual(lines, want) {
		t.Errorf("dots row: got %q, want %q", lines, want)
	}
}

func TestStatDotsClampAndCoerce(t *testing.T) {
	cases := []struct {
		dots map[string]any
		want string
	}{
		{map[string]any{"on": 99.0, "of": 3.0}, "●●● 3/3"},
		{map[string]any{"on": -4.0, "of": 3.0}, "○○○ 0/3"},
		{map[string]any{"on": "1", "of": " 4 "}, "●○○○ 1/4"},
	}
	for _, c := range cases {
		lines := plainCell(map[string]any{"value": "1", "dots": c.dots}, 40)
		if len(lines) != 2 || lines[1] != c.want {
			t.Errorf("dots %v: got %q, want row %q", c.dots, lines, c.want)
		}
	}
}

func TestStatDotsMalformedIsByteIdentical(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor}
	bare := statCell(map[string]any{"value": "1"}, ctx)
	for _, dots := range []any{
		nil, "x", []any{},
		map[string]any{"on": 1.0},
		map[string]any{"on": 1.0, "of": 0.0},
		map[string]any{"on": 1.0, "of": 51.0},
		map[string]any{"on": 1.0, "of": 2.5},
		map[string]any{"on": "a", "of": 3.0},
	} {
		got := statCell(map[string]any{"value": "1", "dots": dots}, ctx)
		if !reflect.DeepEqual(got, bare) {
			t.Errorf("dots %v rendered something: %q", dots, got)
		}
	}
}

func TestStatDotsNarrowKeepsTheCount(t *testing.T) {
	lines := plainCell(map[string]any{"value": "2", "dots": map[string]any{"on": 2.0, "of": 10.0}}, 8)
	if len(lines) != 2 || lines[1] != "2/10" || strings.ContainsAny(lines[1], "●○") {
		t.Errorf("narrow: got %q, want the bare count", lines)
	}
}
