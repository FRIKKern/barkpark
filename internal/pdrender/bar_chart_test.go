package pdrender

import (
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// TestBarChartRenderer proves the bar-chart block renders its bars THROUGH
// the registry — one assertion covering both the renderer and its
// DefaultRegistry registration.
func TestBarChartRenderer(t *testing.T) {
	profile := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(profile) })
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{
			map[string]any{"label": "paragraph", "value": 4969},
			map[string]any{"label": "heading", "value": 3232},
		},
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "paragraph") || !strings.Contains(got, "heading") {
		t.Fatalf("bar-chart render missing labels, got %q", got)
	}
}

// TestBarChartRendererValues pins the `values: true` digit readout.
func TestBarChartRendererValues(t *testing.T) {
	profile := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(profile) })
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{
			map[string]any{"label": "paragraph", "value": 4969},
			map[string]any{"label": "heading", "value": 3232},
		},
		"values": true,
	}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "4969") || !strings.Contains(got, "3232") {
		t.Fatalf("bar-chart values render missing digits, got %q", got)
	}
}

// TestBarChartRendererMax proves an explicit `max` sets the meter's
// denominator (a bar at max fills the whole track; the widest bar without an
// explicit max also fills it, so the distinguishing proof is a bar BELOW an
// explicit max staying visibly short).
func TestBarChartRendererMax(t *testing.T) {
	profile := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(profile) })
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{
		"bars": []any{map[string]any{"label": "a", "value": 1}},
		"max":  10,
	}}
	got := reg.Render(b, RenderCtx{Width: 13, Theme: DarkTheme(), Profile: NoColor})
	want := []string{"a  ▓░░░░░░░░░"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("explicit max track: got %q, want %q", got, want)
	}
}

// TestBarChartRendererMaxContract pins the canonical bar_chart_html denominator
// through Decode and the real registry. Ten-cell tracks expose proportions;
// trailing digits stay raw even when the meter clamps negative or excess values.
func TestBarChartRendererMaxContract(t *testing.T) {
	profile := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(profile) })
	reg := testRegistry()
	for _, tt := range []struct {
		name string
		max  string
		want []string
	}{
		{
			name: "explicit max below data",
			max:  `,"max":4`,
			want: []string{"a  ▓▓▓▓▓▓▓▓▓▓  4", "b  ▓▓▓▓▓▓▓▓▓▓  9", "c  ░░░░░░░░░░ -2"},
		},
		{
			name: "explicit max above data",
			max:  `,"max":18`,
			want: []string{"a  ▓▓░░░░░░░░  4", "b  ▓▓▓▓▓░░░░░  9", "c  ░░░░░░░░░░ -2"},
		},
		{
			name: "absent max infers data maximum",
			want: []string{"a  ▓▓▓▓░░░░░░  4", "b  ▓▓▓▓▓▓▓▓▓▓  9", "c  ░░░░░░░░░░ -2"},
		},
		{
			name: "zero max infers data maximum",
			max:  `,"max":0`,
			want: []string{"a  ▓▓▓▓░░░░░░  4", "b  ▓▓▓▓▓▓▓▓▓▓  9", "c  ░░░░░░░░░░ -2"},
		},
		{
			name: "negative max infers data maximum",
			max:  `,"max":-3`,
			want: []string{"a  ▓▓▓▓░░░░░░  4", "b  ▓▓▓▓▓▓▓▓▓▓  9", "c  ░░░░░░░░░░ -2"},
		},
	} {
		t.Run(tt.name, func(t *testing.T) {
			source := `[ {"type":"bar-chart","values":true,"bars":[
				{"label":" a ","value":4},{"label":"b","value":9},{"label":"c","value":-2}
			]` + tt.max + `} ]`
			raw := []byte(source)
			blocks, err := Decode(raw)
			if err != nil || len(blocks) != 1 {
				t.Fatalf("decode chart: blocks=%v, err=%v", blocks, err)
			}
			before, err := Decode([]byte(source))
			if err != nil {
				t.Fatal(err)
			}
			got := reg.Render(blocks[0], RenderCtx{Width: 16, Theme: DarkTheme(), Profile: NoColor})
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("tracks and raw digits: got %q, want %q", got, tt.want)
			}
			if string(raw) != source || !reflect.DeepEqual(blocks, before) {
				t.Fatalf("render mutated source: raw=%q, blocks=%#v, before=%#v", raw, blocks, before)
			}
		})
	}
}

// TestBarChartRendererEmptyIsSilent pins the honest empty state: a
// bar-chart block with no bars contributes zero lines.
func TestBarChartRendererEmptyIsSilent(t *testing.T) {
	profile := lipgloss.ColorProfile()
	t.Cleanup(func() { lipgloss.SetColorProfile(profile) })
	reg := testRegistry()
	b := Block{Type: "bar-chart", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty bar-chart should render nothing, got %d lines", len(lines))
	}
}
