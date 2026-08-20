package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// sampleUnifiedDiff is a small real-shaped git diff: metadata lines, one file
// header pair, one hunk, adds/removes/context.
const sampleUnifiedDiff = `diff --git a/internal/pdrender/diff.go b/internal/pdrender/diff.go
index 3f9c2aa..b71d0e4 100644
--- a/internal/pdrender/diff.go
+++ b/internal/pdrender/diff.go
@@ -1,4 +1,5 @@
 package pdrender
-// starter render
+// real renderer
+// shared row vocabulary
 type diffRenderer struct{}`

// TestDiffRenderer proves the grown diff block renders a verbatim unified
// diff THROUGH the registry — one pass covering the renderer, its
// DefaultRegistry registration, and the D77 row grammar: bold per-file path
// sub-header, verbatim @@ hunk row, +/- prefixes as the semantic carrier
// (NoColor profile — the prefixes must survive an ansi.Strip).
func TestDiffRenderer(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"diff": sampleUnifiedDiff}}
	lines := reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	got := ansi.Strip(strings.Join(lines, "\n"))

	// Header tally: 2 adds, 1 remove (metadata --- / +++ never counted).
	if !strings.Contains(got, "+2 −1") {
		t.Fatalf("diff header tally missing, got:\n%s", got)
	}
	// The +++ transition mints a path sub-header (a/ b/ prefixes dropped).
	if !strings.Contains(got, "internal/pdrender/diff.go") {
		t.Fatalf("path sub-header missing, got:\n%s", got)
	}
	// The @@ hunk header renders verbatim — line numbers load-bearing (D77).
	if !strings.Contains(got, "@@ -1,4 +1,5 @@") {
		t.Fatalf("hunk header not verbatim, got:\n%s", got)
	}
	// +/- prefixes carry semantics without color.
	if !strings.Contains(got, "+ // real renderer") || !strings.Contains(got, "- // starter render") {
		t.Fatalf("+/- prefix rows missing, got:\n%s", got)
	}
	// Context rows keep the two-space gutter alignment.
	if !strings.Contains(got, "  package pdrender") {
		t.Fatalf("context row missing, got:\n%s", got)
	}
	// Metadata lines are folded away entirely.
	if strings.Contains(got, "diff --git") || strings.Contains(got, "index 3f9c2aa") {
		t.Fatalf("metadata lines leaked into render, got:\n%s", got)
	}
}

// TestDiffRendererFileAttrHeader pins the optional `file` attr: a bold path +
// tally header row, the same header shape as chat-tool-diff.
func TestDiffRendererFileAttrHeader(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{
		"file": "lib/example.ex",
		"diff": "@@ -1 +1 @@\n-old\n+new",
	}}
	lines := reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})
	head := ansi.Strip(lines[0])
	if !strings.Contains(head, "lib/example.ex") || !strings.Contains(head, "+1 −1") {
		t.Fatalf("file header row wrong, got %q", head)
	}
}

// TestDiffRendererBudgetFold pins the shared 20-line budget: a diff body past
// chatDiffBudget rows folds behind the honest "… +N more lines" footnote and
// draws exactly chatDiffBudget body rows.
func TestDiffRendererBudgetFold(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("@@ -1,0 +1,30 @@\n")
	for i := 0; i < 30; i++ {
		sb.WriteString("+line " + itoa(i) + "\n")
	}
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"diff": sb.String()}}
	lines := reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor})

	// 1 header + chatDiffBudget body rows + 1 overflow footnote.
	if len(lines) != 1+chatDiffBudget+1 {
		t.Fatalf("expected %d lines, got %d:\n%s", 1+chatDiffBudget+1, len(lines), strings.Join(lines, "\n"))
	}
	// 31 drawable rows (hunk + 30 adds) − 20 drawn = 11 folded.
	last := ansi.Strip(lines[len(lines)-1])
	if !strings.Contains(last, "… +11 more lines") {
		t.Fatalf("overflow footnote wrong, got %q", last)
	}
}

// TestDiffRendererMultiFile pins D77's honest multi-file degrade: one bold
// path sub-header per +++ transition, and a deletion's `+++ /dev/null`
// falling back to the old `---` path.
func TestDiffRendererMultiFile(t *testing.T) {
	diff := "--- a/first.go\n" +
		"+++ b/first.go\n" +
		"@@ -1 +1 @@\n" +
		"+one\n" +
		"--- a/gone.go\n" +
		"+++ /dev/null\n" +
		"@@ -1 +0,0 @@\n" +
		"-bye\n"
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"diff": diff}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "first.go") {
		t.Fatalf("first file header missing, got:\n%s", got)
	}
	if !strings.Contains(got, "gone.go") {
		t.Fatalf("deleted-file header (via --- fallback) missing, got:\n%s", got)
	}
	if strings.Contains(got, "/dev/null") {
		t.Fatalf("/dev/null leaked as a header, got:\n%s", got)
	}
}

// TestDiffRendererTruncatesNeverWraps pins the column-alignment law: an
// over-width diff row cell-truncates into ONE line, never re-wraps.
func TestDiffRendererTruncatesNeverWraps(t *testing.T) {
	long := "+" + strings.Repeat("x", 200)
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"diff": long}}
	lines := reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	if len(lines) != 2 { // header + one truncated row
		t.Fatalf("long diff row wrapped: got %d lines", len(lines))
	}
	if w := ansi.StringWidth(lines[1]); w > 40 {
		t.Fatalf("row not truncated to width, got %d cells", w)
	}
}

// TestDiffRendererStarterTextFallback keeps the round-1 starter contract
// honest: a block born with only a `text` attr still renders (as context
// rows) instead of vanishing.
func TestDiffRendererStarterTextFallback(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{"text": "hello from diff"}}
	got := ansi.Strip(strings.Join(reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}), "\n"))
	if !strings.Contains(got, "hello from diff") {
		t.Fatalf("diff render missing text, got %q", got)
	}
}

// TestDiffRendererEmptyIsSilent pins the honest empty state: a
// diff block with no text contributes zero lines.
func TestDiffRendererEmptyIsSilent(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "diff", Attrs: map[string]any{}}
	if lines := reg.Render(b, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}); len(lines) != 0 {
		t.Fatalf("empty diff should render nothing, got %d lines", len(lines))
	}
}
