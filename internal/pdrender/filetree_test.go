package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

const sampleTree = `internal/pdrender/
├── diff.go ● created
├── filetree.go ● created
├── chat_blocks.go ○ shared
└── legacy.go ✕ removed`

// TestFiletreeRenderer proves the grown filetree block renders verbatim tree
// lines THROUGH the registry — box glyphs and indentation preserved, the D78
// annotation glyph kept IN the text stream (NoColor profile: an ansi.Strip
// must still carry the full ` ● created` annotation), and the optional
// legend attr as a trailing row.
func TestFiletreeRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{
		"text":   sampleTree,
		"legend": "● created · ○ shared · ✕ removed",
	}}
	lines := reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	got := ansi.Strip(strings.Join(lines, "\n"))

	// Verbatim tree lines: box glyphs survive, one output row per input line
	// plus the legend.
	if len(lines) != 5+1 {
		t.Fatalf("expected 6 rows (5 tree + legend), got %d:\n%s", len(lines), got)
	}
	if !strings.Contains(got, "├── diff.go ● created") {
		t.Fatalf("annotated tree line not carried in text stream, got:\n%s", got)
	}
	if !strings.Contains(got, "└── legacy.go ✕ removed") {
		t.Fatalf("✕ annotation missing, got:\n%s", got)
	}
	if !strings.Contains(got, "chat_blocks.go ○ shared") {
		t.Fatalf("○ annotation missing, got:\n%s", got)
	}
	// The legend row (D78's self-describing convention).
	if !strings.Contains(got, "● created · ○ shared · ✕ removed") {
		t.Fatalf("legend row missing, got:\n%s", got)
	}
	// A line without an annotation renders verbatim, untouched.
	if strings.Split(got, "\n")[0] != "internal/pdrender/" {
		t.Fatalf("plain tree line not verbatim, got %q", strings.Split(got, "\n")[0])
	}
}

// TestFiletreeRendererAnnotationSpan pins the split discipline: the
// annotation splits on the FIRST ` <glyph> ` separator, tree part verbatim to
// its left, note (which may itself mention glyphs) styled to its right.
func TestFiletreeRendererAnnotationSpan(t *testing.T) {
	tree, glyph, note := splitTreeAnnotation("├── a.go ● created ○ later")
	if tree != "├── a.go" || glyph != "●" || note != "created ○ later" {
		t.Fatalf("split wrong: tree=%q glyph=%q note=%q", tree, glyph, note)
	}
	tree, glyph, note = splitTreeAnnotation("├── plain.go")
	if tree != "├── plain.go" || glyph != "" || note != "" {
		t.Fatalf("no-annotation split wrong: tree=%q glyph=%q note=%q", tree, glyph, note)
	}
}

// TestFiletreeRendererDegradeNarrow pins drop-chrome-first (D78): below
// MinWidth the annotation styling and the legend row drop and the tree
// renders as plain truncated text — content survives, chrome goes first.
func TestFiletreeRendererDegradeNarrow(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{
		"text":   sampleTree,
		"legend": "● created",
	}}
	lines := reg.Render(b, RenderCtx{Width: MinWidth - 1, Theme: DarkTheme(), Profile: NoColor})
	if len(lines) != 5 {
		t.Fatalf("narrow degrade should render 5 plain tree rows (no legend), got %d", len(lines))
	}
	for _, ln := range lines {
		if w := ansi.StringWidth(ln); w > MinWidth-1 {
			t.Fatalf("narrow row not truncated, got %d cells: %q", w, ln)
		}
	}
}

// TestFiletreeRendererTruncatesNeverWraps pins the no-reflow law: an
// over-width tree line cell-truncates into ONE row — a wrapped tree line
// would break the box drawing.
func TestFiletreeRendererTruncatesNeverWraps(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{
		"text": "├── " + strings.Repeat("deep/", 40) + "leaf.go ● created",
	}}
	lines := reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	if len(lines) != 1 {
		t.Fatalf("long tree line wrapped: got %d rows", len(lines))
	}
	if w := ansi.StringWidth(lines[0]); w > 40 {
		t.Fatalf("row not truncated to width, got %d cells", w)
	}
}

// TestFiletreeRendererEmptyIsSilent pins the honest empty state: a
// filetree block with no text contributes zero lines.
func TestFiletreeRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "filetree", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty filetree should render nothing, got %d lines", len(lines))
	}
}
