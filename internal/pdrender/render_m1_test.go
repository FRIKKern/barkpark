package pdrender

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// stubRefResolver is the caller-supplied resolver seam under test: it maps the
// fixture's reference id "a1" → a human title. Mirrors how the TUI would inject
// &Content.reference_title.
func stubRefResolver(id, refType string) string {
	if id == "a1" && refType == "author" {
		return "Knut Hamsun"
	}
	return ""
}

// renderM1Fixture renders the M1 fixture with NoColor pinned (byte-stable
// goldens) AND the stub RefResolver wired so field-reference resolves a title.
func renderM1Fixture(t *testing.T, name string, width int) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	blocks, err := Decode(raw)
	if err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	reg := testRegistry() // pins lipgloss to Ascii (NoColor)
	ctx := RenderCtx{
		Width:       width,
		Theme:       DarkTheme(),
		Profile:     NoColor,
		RefResolver: stubRefResolver,
	}
	out := reg.RenderDoc(blocks, ctx)
	stripped := ansi.Strip(out)
	// Shared blind-spot guard (unknown_block_guard_test.go): a golden diffed
	// against Go's OWN render cannot see a fallback box that appears on BOTH
	// sides. This is the one call that can.
	assertNoUnknownBlock(t, name, stripped)
	return stripped
}

// TestGoldenM1 renders the M1 block fixture at every golden width and diffs it
// against the checked-in golden (regenerate with -update).
func TestGoldenM1(t *testing.T) {
	const fx = "sample_m1.json"
	for _, w := range goldenWidths {
		w := w
		name := strings.TrimSuffix(fx, ".json")
		t.Run(name+"_w"+itoa(w), func(t *testing.T) {
			got := renderM1Fixture(t, fx, w)
			goldenPath := filepath.Join("testdata", "golden", name+"_w"+itoa(w)+".txt")
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
				t.Errorf("M1 render mismatch at width %d\n--- got ---\n%s\n--- want ---\n%s",
					w, got, string(want))
			}
		})
	}
}

// TestCodeEmitsSGRAtANSI256 proves chroma highlighting actually fires: at
// Profile=ANSI256 the code renderer must emit SGR color escapes (\x1b[…m). This
// is the "color is real" guard the byte-stable NoColor goldens can't make.
func TestCodeEmitsSGRAtANSI256(t *testing.T) {
	// Force a real color profile so chroma's terminal256 formatter emits escapes.
	// NOTE the termenv enum is INVERTED: TrueColor=0, ANSI256=1, ANSI=2, Ascii=3.
	// We restore to Ascii(3) in cleanup so any later golden render strips clean.
	// (Chroma's own formatter choice is driven by ctx.Profile, independent of the
	// lipgloss global — this only governs whether lipgloss/chroma escapes survive.)
	lipgloss.SetColorProfile(1) // termenv.ANSI256
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	reg := DefaultRegistry(DarkTheme())
	block := Block{
		Type: "code",
		Attrs: map[string]any{
			"type":  "code",
			"value": "func main() {\n\tprintln(\"hi\")\n}",
		},
	}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: ANSI256}), "\n")

	if !strings.Contains(out, "\x1b[") {
		t.Fatalf("expected SGR escapes from chroma at ANSI256, got none:\n%q", out)
	}
	// The terminal256 formatter uses the 38;5;<n> indexed-color form.
	if !strings.Contains(out, "38;5;") {
		t.Errorf("expected indexed-256 color codes (38;5;…) at ANSI256, got:\n%q", out)
	}
}

// TestFieldColorEmitsBackgroundEscape proves field-color paints a REAL terminal
// swatch: at a color profile the swatch cell must carry a background-color SGR
// (48;… form). Only strict #rgb/#rrggbb values get a swatch.
func TestFieldColorEmitsBackgroundEscape(t *testing.T) {
	// termenv enum is inverted: TrueColor=0 → swatch emits a 48;2;r;g;b bg.
	lipgloss.SetColorProfile(0) // termenv.TrueColor
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	reg := DefaultRegistry(DarkTheme())
	block := Block{
		Type: "field-color",
		Attrs: map[string]any{
			"type":  "field-color",
			"label": "Accent",
			"value": "#a23925",
		},
	}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor}), "\n")

	// A background SGR opens with 48; (48;2;… truecolor / 48;5;… indexed).
	if !strings.Contains(out, "\x1b[48;") {
		t.Fatalf("expected a background-color escape (\\x1b[48;…) for the swatch, got:\n%q", out)
	}
	// The hex text still renders beside the swatch.
	if !strings.Contains(ansi.Strip(out), "#a23925") {
		t.Errorf("expected the hex text beside the swatch, got:\n%s", ansi.Strip(out))
	}
}

// TestFieldColorNoSwatchForNonHex asserts an arbitrary (non-hex) value gets NO
// background escape — the swatch is strict-hex only (mirrors safe_hex/1).
func TestFieldColorNoSwatchForNonHex(t *testing.T) {
	lipgloss.SetColorProfile(0) // termenv.TrueColor
	t.Cleanup(func() { lipgloss.SetColorProfile(3) })

	reg := DefaultRegistry(DarkTheme())
	block := Block{
		Type: "field-color",
		Attrs: map[string]any{
			"type":  "field-color",
			"label": "Bad",
			"value": "red; evil",
		},
	}
	out := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor}), "\n")
	if strings.Contains(out, "\x1b[48;") {
		t.Errorf("non-hex value must not paint a swatch, got a bg escape:\n%q", out)
	}
}

// TestCodeMemoization asserts the code renderer caches by (content,width,theme,
// profile): rendering the SAME block twice produces ONE chroma run (one miss,
// one hit) and identical output. This is the manual equivalent of React
// skipping an unchanged subtree.
func TestCodeMemoization(t *testing.T) {
	cr := newCodeRenderer()
	block := Block{
		Type: "code",
		Attrs: map[string]any{
			"type":  "code",
			"value": "let x = 1\nlet y = 2",
		},
	}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: ANSI256}

	first := cr.Render(block, ctx)
	second := cr.Render(block, ctx)

	if cr.misses != 1 {
		t.Errorf("expected exactly 1 cache miss (one chroma run), got %d", cr.misses)
	}
	if cr.hits != 1 {
		t.Errorf("expected exactly 1 cache hit on the second render, got %d", cr.hits)
	}
	if strings.Join(first, "\n") != strings.Join(second, "\n") {
		t.Errorf("memoized render diverged:\nfirst:  %q\nsecond: %q", first, second)
	}

	// A different width is a different key → a new miss, not a hit.
	cr.Render(block, ctx.WithWidth(40))
	if cr.misses != 2 {
		t.Errorf("expected a new miss for a different width, misses=%d", cr.misses)
	}
}

// boldLeadRe matches an SGR run that opens with the bold attribute (1) and is
// immediately followed by the author's "Figure 2." lead.
var boldLeadRe = regexp.MustCompile(`\x1b\[1(;[0-9;]*)?mFigure 2\.`)

// TestStatLabelKeepsEveryWrappedLine is the TRUNCATION TRIPWIRE: a stat cell's
// label is authored content, so every wrapped line must reach the terminal. The
// cell used to emit firstLine(wrapLines(label)) — at a wide render the trailing
// " Aug" of "remedies executed on GitHub, 12 Aug" vanished into a cell whose
// resolved width was narrower than the label, silently losing the author's words.
func TestStatLabelKeepsEveryWrappedLine(t *testing.T) {
	const label = "remedies executed on GitHub, 12 Aug"
	ctx := RenderCtx{Width: 24, Theme: DarkTheme(), Profile: NoColor}
	lines := statCell(map[string]any{"value": "9", "label": label}, ctx)
	joined := ansi.Strip(strings.Join(lines, "\n"))

	if !strings.Contains(joined, "Aug") {
		t.Errorf("stat label truncated — %q lost its tail:\n%s", label, joined)
	}
	// The label wrapped (its width exceeds the cell), so it must span >1 line and
	// every authored word must survive somewhere in the cell.
	if len(lines) < 3 {
		t.Errorf("expected value + at least two wrapped label lines, got %d:\n%s", len(lines), joined)
	}
	for _, word := range strings.Fields(label) {
		if !strings.Contains(joined, word) {
			t.Errorf("stat label lost the word %q:\n%s", word, joined)
		}
	}
}

// TestFigureCaptionsAreAuthorTruth is the INVENTION TRIPWIRE: pdrender must
// print exactly the caption the author typed — never a number of its own. The
// old document-global counter made the terminal contradict the author (a paper
// whose captions already read "Figure 2. …" rendered "Figure 1. Figure 2. …"),
// and it numbered children before parents. The web reader only EMPHASISES an
// author-typed lead (figures.ex figcaption_inner/1); this pins the same rule.
func TestFigureCaptionsAreAuthorTruth(t *testing.T) {
	fig := func(caption, text string) Block {
		return Block{Type: "figure", Attrs: map[string]any{"type": "figure", "caption": caption},
			Child: &Block{Type: "paragraph", Attrs: map[string]any{"type": "paragraph",
				"content": []any{map[string]any{"type": "text", "value": text}}}}}
	}
	reg := testRegistry()
	ctx := RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}

	// Unnumbered captions stay unnumbered — no "Figure" appears anywhere.
	plain := ansi.Strip(reg.RenderDoc([]Block{fig("first", "a"), fig("second", "b")}, ctx))
	if strings.Contains(plain, "Figure") {
		t.Errorf("pdrender generated a figure number the author never typed:\n%s", plain)
	}
	for _, want := range []string{"first", "second"} {
		if !strings.Contains(plain, want) {
			t.Errorf("lost the author's caption %q:\n%s", want, plain)
		}
	}

	// An author-typed lead survives verbatim, exactly once, with no second number
	// bolted on in front of it.
	numbered := ansi.Strip(reg.RenderDoc([]Block{fig("Figure 2. The ingest path.", "a")}, ctx))
	if strings.Count(numbered, "Figure") != 1 {
		t.Errorf("expected the author's single 'Figure 2.' lead, got:\n%s", numbered)
	}
	if !strings.Contains(numbered, "Figure 2. The ingest path.") {
		t.Errorf("author's numbered caption not rendered intact:\n%s", numbered)
	}

	// …and that lead is EMPHASISED (bold) when the terminal can style, the analogue
	// of the web's <b> run-in. The suite's default profile emits no SGR, so ask for
	// real escapes the way heading_alias_drift_test does.
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	defer lipgloss.SetColorProfile(oldProfile)
	styled := reg.RenderDoc([]Block{fig("Figure 2. The ingest path.", "a")},
		RenderCtx{Width: 60, Theme: DarkTheme(), Profile: TrueColor})
	// The lead carries its own SGR run opening with the bold attribute (1); the
	// remainder of the caption is the plain caption tone.
	if !boldLeadRe.MatchString(styled) {
		t.Errorf("expected a bold run-in on the author's 'Figure 2.' lead:\n%q", styled)
	}
	if !strings.Contains(styled, "Figure 2.\x1b[0m") {
		t.Errorf("expected the lead to close as its own styled run:\n%q", styled)
	}
}

// TestActionOSC8Gating checks the action CTA emits an OSC8 link at a high
// profile and a dim suffix at NoColor.
func TestActionOSC8Gating(t *testing.T) {
	reg := testRegistry()
	block := Block{Type: "action", Attrs: map[string]any{
		"type": "action", "label": "Go", "href": "https://x.example", "priority": "primary",
	}}

	hi := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: TrueColor}), "\n")
	if !strings.Contains(hi, "\x1b]8;;https://x.example\x1b\\") {
		t.Errorf("expected OSC8 link at TrueColor, got %q", hi)
	}

	lo := strings.Join(reg.Render(block, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n")
	if strings.Contains(lo, "\x1b]8;;") {
		t.Errorf("did not expect OSC8 at NoColor, got %q", lo)
	}
	if !strings.Contains(ansi.Strip(lo), "(https://x.example)") {
		t.Errorf("expected dim href suffix at NoColor, got %q", ansi.Strip(lo))
	}
}

// TestFieldReferenceResolver checks the injected resolver wins, with raw-id and
// em-dash fallbacks.
func TestFieldReferenceResolver(t *testing.T) {
	reg := testRegistry()
	mk := func(value string) Block {
		return Block{Type: "field-reference", Attrs: map[string]any{
			"type": "field-reference", "label": "Author", "refType": "author", "value": value,
		}}
	}

	// Resolver present → title.
	withRes := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor, RefResolver: stubRefResolver}
	got := ansi.Strip(strings.Join(reg.Render(mk("a1"), withRes), "\n"))
	if !strings.Contains(got, "Knut Hamsun") {
		t.Errorf("expected resolved title, got %q", got)
	}

	// No resolver → raw id.
	noRes := RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}
	got = ansi.Strip(strings.Join(reg.Render(mk("a1"), noRes), "\n"))
	if !strings.Contains(got, "a1") {
		t.Errorf("expected raw id fallback, got %q", got)
	}

	// Empty value → em-dash.
	got = ansi.Strip(strings.Join(reg.Render(mk(""), withRes), "\n"))
	if !strings.Contains(got, "—") {
		t.Errorf("expected em-dash for empty reference, got %q", got)
	}
}
