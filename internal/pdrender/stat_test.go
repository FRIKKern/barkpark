package pdrender

import (
	"encoding/json"
	"reflect"

	"github.com/charmbracelet/lipgloss"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestSparklineMapping is the load-bearing proof of the eighth-block primitive:
// a strictly ascending series maps ONE glyph per value across the full ladder
// ▁▂▃▄▅▆▇█ (min→▁, max→█), normalised to the series' own min..max.
func TestSparklineMapping(t *testing.T) {
	// Eight ascending values → the exact eighth-block ladder, in order.
	got := sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 0)
	if want := "▁▂▃▄▅▆▇█"; got != want {
		t.Fatalf("ascending series: got %q, want %q", got, want)
	}

	// Endpoints: the series minimum lands on ▁, the maximum on █, regardless of
	// the absolute scale (here 100..800, big non-unit values).
	got = sparkline([]float64{100, 800}, 0)
	if first, last := []rune(got)[0], []rune(got)[1]; string(first) != "▁" || string(last) != "█" {
		t.Errorf("scaled endpoints: got %q, want first ▁ and last █", got)
	}
}

// TestSparklineGuards pins the divide-by-zero / empty guards: an empty series
// draws nothing; a flat (constant) series draws a baseline row of the lowest
// glyph rather than dividing by a zero span.
func TestSparklineGuards(t *testing.T) {
	if got := sparkline(nil, 10); got != "" {
		t.Errorf("empty series: got %q, want \"\"", got)
	}
	if got := sparkline([]float64{}, 10); got != "" {
		t.Errorf("empty slice: got %q, want \"\"", got)
	}
	// Flat series → baseline (lowest glyph) row, one per value, no panic/NaN.
	if got := sparkline([]float64{5, 5, 5, 5}, 10); got != "▁▁▁▁" {
		t.Errorf("flat series: got %q, want ▁▁▁▁ (baseline)", got)
	}
	// A single point is degenerate (span 0) → baseline glyph, not a divide-by-zero.
	if got := sparkline([]float64{42}, 10); got != "▁" {
		t.Errorf("single point: got %q, want ▁", got)
	}
}

// TestSparklineWidthBound pins the width cap: with width < len(values), the
// glyph count is bounded to width (the caller passes the cell width).
func TestSparklineWidthBound(t *testing.T) {
	got := sparkline([]float64{1, 2, 3, 4, 5, 6, 7, 8}, 3)
	if n := len([]rune(got)); n != 3 {
		t.Fatalf("width bound: got %d glyphs (%q), want 3", n, got)
	}
}

// TestStatModeBranch covers the max-presence mode branch of the single stat cell:
// big-number (no max) renders the value prominently with no bar glyphs; bullet-bar
// (max present) draws the ▓/░ proportion bar; a missing value degrades to the dim
// placeholder.
func TestStatModeBranch(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}

	// Big-number: no max → the value, no bar glyphs.
	big := statCell(map[string]any{"value": "1.24M", "label": "Tokens"}, ctx)
	joined := strings.Join(big, "\n")
	if !strings.Contains(joined, "1.24M") {
		t.Errorf("big-number: value %q missing from %q", "1.24M", joined)
	}
	if strings.ContainsAny(joined, "▓░") {
		t.Errorf("big-number: unexpected bullet-bar glyphs in %q", joined)
	}

	// Bullet-bar: max present → the ▓/░ proportion bar appears.
	bar := statCell(map[string]any{"value": "73", "max": 100.0, "label": "Cache hit"}, ctx)
	joinedBar := strings.Join(bar, "\n")
	if !strings.ContainsAny(joinedBar, "▓░") {
		t.Errorf("bullet-bar: expected a ▓/░ bar in %q", joinedBar)
	}
	if !strings.Contains(joinedBar, "73") {
		t.Errorf("bullet-bar: value 73 missing from %q", joinedBar)
	}

	// Degrade: no value key → the dim placeholder.
	deg := statCell(map[string]any{"label": "orphan"}, ctx)
	if len(deg) != 1 || !strings.Contains(deg[0], "stat") || !strings.Contains(deg[0], "unresolved") {
		t.Errorf("degrade: expected a [stat — unresolved] placeholder, got %q", deg)
	}
}

// TestStatSparkIntegration proves the sparkline row is emitted beneath a stat
// that carries a `spark` series.
func TestStatSparkIntegration(t *testing.T) {
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	lines := statCell(map[string]any{"value": "up", "spark": []any{1.0, 2.0, 3.0, 8.0}}, ctx)
	joined := strings.Join(lines, "\n")
	if !strings.ContainsAny(joined, string(sparkLadder[:])) {
		t.Errorf("spark integration: expected an eighth-block glyph in %q", joined)
	}
}

// TestStatsGridNUp proves the plural KPI grid lays cells side-by-side at a wide
// width (two cells share a line) and stacks them at a narrow width.
func TestStatsGridNUp(t *testing.T) {
	grid := Block{
		Type: "stats",
		Attrs: map[string]any{
			"items": []any{
				map[string]any{"value": "1.24M", "label": "Tokens"},
				map[string]any{"value": "8,391", "label": "Requests"},
			},
		},
	}

	// Wide: 2-up → both values on the SAME line.
	wide := statsRenderer{}.Render(grid, RenderCtx{Width: 120, Theme: DarkTheme(), Profile: NoColor})
	sideBySide := false
	for _, ln := range wide {
		if strings.Contains(ln, "1.24M") && strings.Contains(ln, "8,391") {
			sideBySide = true
		}
	}
	if !sideBySide {
		t.Errorf("wide grid: expected both cells on one line, got %q", wide)
	}

	// Narrow: below the Flex MinWidth floor → stack (never on one line).
	narrow := statsRenderer{}.Render(grid, RenderCtx{Width: 24, Theme: DarkTheme(), Profile: NoColor})
	for _, ln := range narrow {
		if strings.Contains(ln, "1.24M") && strings.Contains(ln, "8,391") {
			t.Errorf("narrow grid: cells should stack, but shared a line: %q", ln)
		}
	}
}

func TestStatContextRegistry(t *testing.T) {
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	b := Block{Type: "stat", Attrs: map[string]any{
		"value": "71", "denom": "118", "unit": "tasks", "label": "Done",
		"body": "Completed this week", "spark": []any{1, 8}, "source": "commit:abcdef0123",
	}}
	got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
	want := "71/118 tasks\nDone\nCompleted this week\n▁█\nKilde: commit:abcdef0"
	if got != want {
		t.Fatalf("stat context: got %q, want %q", got, want)
	}
}

func TestStatsContextRegistry(t *testing.T) {
	b := Block{Type: "stats", Attrs: map[string]any{
		"sourceDefault": "paper:report",
		"items": []any{
			map[string]any{"value": "5", "unit": "kg", "label": "Mass", "body": "First load"},
			map[string]any{"value": "8", "unit": "ms", "label": "Time", "body": "Last run"},
		},
	}}
	for _, tc := range []struct {
		width int
		want  string
	}{
		{24, "5 kg\nMass\nFirst load\n\n8 ms\nTime\nLast run\nKilde: paper:report"},
		{42, "5 kg" + strings.Repeat(" ", 18) + "8 ms" + strings.Repeat(" ", 16) + "\n" +
			"Mass" + strings.Repeat(" ", 18) + "Time" + strings.Repeat(" ", 16) + "\n" +
			"First load" + strings.Repeat(" ", 12) + "Last run" + strings.Repeat(" ", 12) + "\nKilde: paper:report"},
	} {
		ctx := RenderCtx{Width: tc.width, Theme: DarkTheme(), Profile: NoColor}
		got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
		if got != tc.want {
			t.Errorf("width %d: got %q, want %q", tc.width, got, tc.want)
		}
	}
}

func TestStatContextSources(t *testing.T) {
	for _, tc := range []struct {
		name  string
		attrs map[string]any
		want  string
	}{
		{"paper", map[string]any{"value": "1", "source": " paper:report "}, "1\nKilde: paper:report"},
		{"task", map[string]any{"value": "1", "source": "task:Task_1.2"}, "1\nKilde: task:Task_1.2"},
		{"https", map[string]any{"value": "1", "source": "https://example.org/report/"}, "1\nKilde: example.org/report"},
		{"invalid", map[string]any{"value": "1", "source": "commit:XYZ"}, "1"},
		{"no singular fallback", map[string]any{"value": "1", "sourceDefault": "paper:report"}, "1"},
		{"missing", map[string]any{"label": "Hidden", "body": "Hidden", "unit": "kg", "source": "paper:report"}, "[stat — unresolved]"},
		{"empty", map[string]any{"value": "", "label": "Caption", "source": "paper:report"}, "\nCaption"},
		{"blank", map[string]any{"value": " \t ", "label": "Caption", "source": "paper:report"}, "\nCaption"},
		{"nil", map[string]any{"value": nil, "label": "Caption", "source": "paper:report"}, "\nCaption"},
		{"zero", map[string]any{"value": 0, "source": "paper:report"}, "0\nKilde: paper:report"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
			got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(Block{Type: "stat", Attrs: tc.attrs}, ctx), "\n"))
			if got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestStatsContextSourceAggregation(t *testing.T) {
	b := Block{Type: "stats", Attrs: map[string]any{
		"sourceDefault": " paper:default ",
		"items": []any{
			map[string]any{"value": "1", "source": "task:first"},
			map[string]any{"value": "2"},
			map[string]any{"value": "3", "source": " task:first "},
			map[string]any{"value": "4", "source": "commit:abcdef0111"},
			map[string]any{"value": "5", "source": "commit:abcdef0222"}, // Same label, distinct raw refs.
			map[string]any{"value": "6", "source": "commit:INVALID"},    // Invalid override must not fall back.
			map[string]any{"value": "7", "source": " \t "},
			map[string]any{"label": "Missing", "source": "paper:missing"},
			map[string]any{"value": "", "source": "paper:empty"},
			map[string]any{"value": " \t ", "source": "paper:blank"},
			map[string]any{"value": nil, "source": "paper:nil"},
		},
	}}
	before, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	for _, width := range []int{24, 400} {
		ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: NoColor}
		lines := DefaultRegistry(ctx.Theme).Render(b, ctx)
		got := ansi.Strip(strings.Join(lines, "\n"))
		start := strings.Index(got, "Kilder:")
		if start < 0 {
			t.Fatalf("width %d: missing footer in %q", width, got)
		}
		want := "Kilder: task:first · paper:default · commit:abcdef0 · commit:abcdef0"
		if footer := strings.Join(strings.Fields(got[start:]), " "); footer != want {
			t.Errorf("width %d: footer %q, want %q", width, footer, want)
		}
		if strings.Count(got, "Kilde") != 1 {
			t.Errorf("width %d: cells emitted extra footers: %q", width, got)
		}
		for _, line := range lines {
			if ansi.StringWidth(line) > width {
				t.Errorf("width %d exceeded: %q", width, line)
			}
		}
		after, err := json.Marshal(b)
		if err != nil {
			t.Fatal(err)
		}
		if string(after) != string(before) {
			t.Fatal("render mutated the source tree")
		}
	}
	// Pin the invalid-override rule independently of another cell using the default.
	b.Attrs["items"] = []any{map[string]any{"value": "1", "source": "bad"}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	if got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n")); got != "1" {
		t.Fatalf("invalid override fell back to the default: %q", got)
	}
}

func TestStatContextBodyWrapping(t *testing.T) {
	body := "one two three four five six seven eight nine ten eleven twelve"
	b := Block{Type: "stat", Attrs: map[string]any{"value": "1", "label": "Count", "body": body, "spark": []any{1, 8}}}
	for _, tc := range []struct {
		width int
		want  string
	}{
		{20, "1\nCount\none two three four\nfive six seven eight\nnine ten eleven\ntwelve\n▁█"},
		{24, "1\nCount\none two three four five\nsix seven eight nine ten\neleven twelve\n▁█"},
		{80, "1\nCount\none two three four five six seven eight nine ten eleven twelve\n▁█"},
	} {
		ctx := RenderCtx{Width: tc.width, Theme: DarkTheme(), Profile: NoColor}
		got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
		if got != tc.want {
			t.Errorf("width %d: got %q, want %q", tc.width, got, tc.want)
		}
	}
	// The second cell ends early: the full body and spark must survive height padding.
	grid := Block{Type: "stats", Attrs: map[string]any{"items": []any{b.Attrs, map[string]any{"value": "2"}}}}
	ctx := RenderCtx{Width: 42, Theme: DarkTheme(), Profile: NoColor}
	got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(grid, ctx), "\n"))
	want := "1" + strings.Repeat(" ", 21) + "2" + strings.Repeat(" ", 19) + "\n" +
		"Count" + strings.Repeat(" ", 37) + "\n" +
		"one two three four" + strings.Repeat(" ", 24) + "\n" +
		"five six seven eight" + strings.Repeat(" ", 22) + "\n" +
		"nine ten eleven" + strings.Repeat(" ", 27) + "\n" +
		"twelve" + strings.Repeat(" ", 36) + "\n" + "▁█" + strings.Repeat(" ", 40)
	if got != want {
		t.Fatalf("uneven grid: got %q, want %q", got, want)
	}
}

func TestStatContextUnitWidth(t *testing.T) {
	for _, tc := range []struct {
		name, unit, want string
		max              any
	}{
		{"unit and denom", "kg", "▓▓▓▓▓▓░░░░░  5/10 kg", 10},
		{"wide glyph", "界", "▓▓▓▓▓▓░░░░░  5/10 界", 10},
		{"nonpositive max", "kg", "5/10 kg", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := RenderCtx{Width: 20, Theme: DarkTheme(), Profile: NoColor}
			b := Block{Type: "stat", Attrs: map[string]any{"value": "5", "denom": "10", "unit": tc.unit, "max": tc.max}}
			got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
			if ansi.StringWidth(got) > 20 {
				t.Errorf("unit width was not reserved: %q", got)
			}
		})
	}
	grid := Block{Type: "stats", Attrs: map[string]any{"sourceDefault": "paper:report", "items": []any{
		map[string]any{"value": "1", "unit": "kilograms-per-person-per-day"}, map[string]any{"value": "2", "unit": "kg"},
	}}}
	ctx := RenderCtx{Width: 42, Theme: DarkTheme(), Profile: NoColor}
	got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(grid, ctx), "\n"))
	want := "1 kilograms-per-person-per-day\n\n2 kg\nKilde: paper:report"
	if got != want {
		t.Fatalf("long unit must force Fits stack: got %q, want %q", got, want)
	}
}

func TestStatContextAbsentCompatibility(t *testing.T) {
	saved := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(saved)
	for _, profile := range []Profile{NoColor, ANSI256, TrueColor} {
		lipgloss.SetColorProfile(lipglossProfileFor(profile))
		ctx := RenderCtx{Width: 42, Theme: DarkTheme(), Profile: profile}
		registry := DefaultRegistry(ctx.Theme)
		for _, typ := range []string{"stat", "stats"} {
			base := map[string]any{"value": "5", "denom": "10", "label": "Count", "spark": []any{1, 8}}
			b := Block{Type: typ, Attrs: base}
			if typ == "stats" {
				b.Attrs = map[string]any{"items": []any{base, map[string]any{"value": "2"}}}
			}
			before := registry.Render(b, ctx)
			visible := ansi.Strip(strings.Join(before, "\n"))
			want := "5/10\nCount\n▁█"
			if typ == "stats" {
				want = "5/10" + strings.Repeat(" ", 18) + "2" + strings.Repeat(" ", 19) + "\nCount" + strings.Repeat(" ", 37) + "\n▁█" + strings.Repeat(" ", 40)
			}
			if visible != want {
				t.Fatalf("%s/%s legacy output: got %q, want %q", typ, profileName(profile), visible, want)
			}
			for _, empty := range []any{nil, "", " \t "} {
				base["unit"], base["body"], base["source"] = empty, empty, empty
				b.Attrs["sourceDefault"] = empty
				if after := registry.Render(b, ctx); !reflect.DeepEqual(after, before) {
					t.Errorf("%s/%s optional %v changed bytes: %q != %q", typ, profileName(profile), empty, after, before)
				}
			}
		}
	}
}

func TestStatContextProfilesAndControls(t *testing.T) {
	b := Block{Type: "stat", Attrs: map[string]any{
		"value": "5", "denom": "10", "max": 10, "unit": "k\x1b[2Jg\x07", "label": "Mass",
		"body": "One\r\nload\t per\x00 day", "source": "https://example.org/\x1b[31mreport\x07/", "spark": []any{1, 8},
	}}
	before, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	for _, typ := range []string{"stat", "stats"} {
		block := b
		block.Type = typ
		if typ == "stats" {
			block.Attrs = map[string]any{"items": []any{b.Attrs, map[string]any{"value": "2", "source": "task:second"}}}
		}
		assertStripComplete(t, "context-"+typ, func(width int, profile Profile) string {
			ctx := RenderCtx{Width: width, Theme: DarkTheme(), Profile: profile}
			return strings.Join(DefaultRegistry(ctx.Theme).Render(block, ctx), "\n")
		})
	}
	saved := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(saved)
	lipgloss.SetColorProfile(lipglossProfileFor(NoColor))
	ctx := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	// Inspect raw output, not ansi.Strip: stripping first would conceal injected controls.
	got := strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n")
	want := "▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░  5/10 k[2Jg\nMass\nOneload per day\n▁█\nKilde: example.org/[31mreport"
	if got != want {
		t.Errorf("raw sanitized output: got %q, want %q", got, want)
	}
	for _, line := range strings.Split(got, "\n") {
		if sanitizeText(line) != line {
			t.Errorf("control survived shared sanitizer: %q", line)
		}
	}
	after, err := json.Marshal(b)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Fatal("profile rendering mutated source")
	}
}

// Optional display fields retain attrStr's existing coercion, not a new admission policy.
func TestStatContextDisplayCoercion(t *testing.T) {
	for _, tc := range []struct {
		field any
		want  string
	}{
		{map[string]any{}, "1 map[]\nmap[]"},
		{[]any{}, "1 []\n[]"},
		{7, "1 7\n7"},
	} {
		ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
		b := Block{Type: "stat", Attrs: map[string]any{"value": "1", "unit": tc.field, "body": tc.field, "source": tc.field}}
		got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
		if got != tc.want {
			t.Fatalf("field %v: got %q, want %q", tc.field, got, tc.want)
		}
	}
}

func TestStatsContextBulletGrid(t *testing.T) {
	b := Block{Type: "stats", Attrs: map[string]any{"items": []any{
		map[string]any{"value": "5", "denom": "10", "max": 10, "unit": "kg"},
		map[string]any{"value": "5", "denom": "10", "max": 10, "unit": "界"},
	}}}
	for _, tc := range []struct {
		width int
		want  string
	}{
		{42, "▓▓▓▓▓▓░░░░░  5/10 kg  ▓▓▓▓▓▓░░░░░  5/10 界"},
		{20, "▓▓▓▓▓▓░░░░░  5/10 kg\n\n▓▓▓▓▓▓░░░░░  5/10 界"},
	} {
		ctx := RenderCtx{Width: tc.width, Theme: DarkTheme(), Profile: NoColor}
		got := ansi.Strip(strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n"))
		if got != tc.want {
			t.Errorf("width %d: got %q, want %q", tc.width, got, tc.want)
		}
	}
}

func TestStatContextDimTone(t *testing.T) {
	saved := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(saved)
	lipgloss.SetColorProfile(lipglossProfileFor(TrueColor))
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: TrueColor}
	b := Block{Type: "stat", Attrs: map[string]any{"value": "71", "denom": "118", "unit": "tasks", "body": "Completed this week", "source": "paper:report"}}
	got := DefaultRegistry(ctx.Theme).Render(b, ctx)
	want := []string{
		ctx.Theme.Body.Bold(true).Render("71") + ctx.Theme.Dim.Render("/118") + ctx.Theme.Dim.Render(" tasks"),
		ctx.Theme.Dim.Render("Completed this week"),
		ctx.Theme.Dim.Render("Kilde: paper:report"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("context must use Dim foreground: got %q, want %q", got, want)
	}
}

func TestStatsContextRawControls(t *testing.T) {
	saved := lipgloss.ColorProfile()
	defer lipgloss.SetColorProfile(saved)
	lipgloss.SetColorProfile(lipglossProfileFor(NoColor))
	b := Block{Type: "stats", Attrs: map[string]any{
		"sourceDefault": "https://example.org/\x1b[2Jdefault\x07/",
		"items": []any{
			map[string]any{"value": "1", "unit": "k\x00g", "body": "First\r\nload", "source": "https://example.org/\x1b[31mreport\x07/"},
			map[string]any{"value": "2", "unit": "m\x7fs", "body": "Next\tload"},
		},
	}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}
	got := strings.Join(DefaultRegistry(ctx.Theme).Render(b, ctx), "\n")
	want := "1 kg" + strings.Repeat(" ", 37) + "2 ms" + strings.Repeat(" ", 35) + "\n" +
		"Firstload" + strings.Repeat(" ", 32) + "Nextload" + strings.Repeat(" ", 31) + "\n" +
		"Kilder: example.org/[31mreport · example.org/[2Jdefault"
	if got != want {
		t.Fatalf("raw grid: got %q, want %q", got, want)
	}
	for _, line := range strings.Split(got, "\n") {
		if sanitizeText(line) != line {
			t.Errorf("raw grid control survived: %q", line)
		}
	}
}
