package taskboard

// mdlite_test.go — block-level contract tests for MarkdownBlocks (charter D16).
// The adapter must (a) recognise exactly the four live-corpus structures, (b)
// degrade EVERYTHING else to a paragraph, and (c) never error/panic on hostile
// input. We assert on the produced pdrender.Block shapes, then prove the whole
// thing renders through the real registry without panic.

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

func blockText(b pdrender.Block) string {
	switch b.Type {
	case "paragraph":
		content, _ := b.Attrs["content"].([]any)
		if len(content) == 1 {
			s, _ := content[0].(string)
			return s
		}
	case "heading":
		s, _ := b.Attrs["text"].(string)
		return s
	case "code":
		s, _ := b.Attrs["code"].(string)
		return s
	}
	return ""
}

func TestMarkdownBlocksEmpty(t *testing.T) {
	for _, src := range []string{"", "   ", "\n\n\n", "\t\n   \n"} {
		if got := MarkdownBlocks(src); got != nil {
			t.Errorf("MarkdownBlocks(%q) = %v, want nil", src, got)
		}
	}
}

func TestMarkdownBlocksParagraphs(t *testing.T) {
	// Soft-wrapped source lines within a paragraph join with a space; a blank
	// line starts a new paragraph.
	src := "first line\nsecond line of the same paragraph\n\nsecond paragraph"
	blocks := MarkdownBlocks(src)
	if len(blocks) != 2 {
		t.Fatalf("got %d blocks, want 2: %#v", len(blocks), blocks)
	}
	if blocks[0].Type != "paragraph" || blockText(blocks[0]) != "first line second line of the same paragraph" {
		t.Errorf("para 0 = %q", blockText(blocks[0]))
	}
	if blockText(blocks[1]) != "second paragraph" {
		t.Errorf("para 1 = %q", blockText(blocks[1]))
	}
}

func TestMarkdownBlocksHeadings(t *testing.T) {
	cases := []struct {
		src   string
		level int
		text  string
	}{
		{"# Title", 1, "Title"},
		{"## Section", 2, "Section"},
		{"### Sub", 3, "Sub"},
		{"#### Deeper still", 3, "Deeper still"}, // clamps to 3
		{"###### Deepest", 3, "Deepest"},
	}
	for _, c := range cases {
		blocks := MarkdownBlocks(c.src)
		if len(blocks) != 1 || blocks[0].Type != "heading" {
			t.Fatalf("%q → %#v, want one heading", c.src, blocks)
		}
		if lvl, _ := blocks[0].Attrs["level"].(int); lvl != c.level {
			t.Errorf("%q level = %d, want %d", c.src, lvl, c.level)
		}
		if got := blockText(blocks[0]); got != c.text {
			t.Errorf("%q text = %q, want %q", c.src, got, c.text)
		}
	}
}

func TestMarkdownBlocksHeadingDegrades(t *testing.T) {
	// No space after the hashes, or 7+ hashes, or empty text → NOT a heading;
	// degrade to a paragraph (never lose the content).
	for _, src := range []string{"#nospace", "####### seven hashes", "#", "## "} {
		blocks := MarkdownBlocks(src)
		if len(blocks) != 1 || blocks[0].Type != "paragraph" {
			t.Errorf("%q → %#v, want one paragraph (degrade)", src, blocks)
		}
	}
}

func TestMarkdownBlocksBullets(t *testing.T) {
	src := "intro paragraph\n\n- alpha\n- beta\n- gamma\n\ntail paragraph"
	blocks := MarkdownBlocks(src)
	if len(blocks) != 3 {
		t.Fatalf("got %d blocks, want 3 (para, list, para): %#v", len(blocks), blocks)
	}
	list := blocks[1]
	if list.Type != "list" {
		t.Fatalf("block 1 type = %q, want list", list.Type)
	}
	if ordered, _ := list.Attrs["ordered"].(bool); ordered {
		t.Errorf("list should be unordered")
	}
	items, _ := list.Attrs["items"].([]any)
	want := []string{"alpha", "beta", "gamma"}
	if len(items) != len(want) {
		t.Fatalf("got %d items, want %d", len(items), len(want))
	}
	for i, it := range items {
		if s, _ := it.(string); s != want[i] {
			t.Errorf("item %d = %v, want %q", i, it, want[i])
		}
	}
}

func TestMarkdownBlocksIndentedBullets(t *testing.T) {
	// Leading indentation is tolerated; the marker must still be `- `.
	blocks := MarkdownBlocks("  - indented item\n  - another")
	if len(blocks) != 1 || blocks[0].Type != "list" {
		t.Fatalf("→ %#v, want one list", blocks)
	}
	items, _ := blocks[0].Attrs["items"].([]any)
	if len(items) != 2 || items[0] != "indented item" {
		t.Errorf("items = %v", items)
	}
}

func TestMarkdownBlocksFencedCode(t *testing.T) {
	src := "before\n\n```go\nfmt.Println(\"hi\")\n\tindented := true\n```\n\nafter"
	blocks := MarkdownBlocks(src)
	if len(blocks) != 3 {
		t.Fatalf("got %d blocks, want 3 (para, code, para): %#v", len(blocks), blocks)
	}
	code := blocks[1]
	if code.Type != "code" {
		t.Fatalf("block 1 type = %q, want code", code.Type)
	}
	if lang, _ := code.Attrs["language"].(string); lang != "go" {
		t.Errorf("code language = %q, want go", lang)
	}
	// Source is verbatim: the tab indentation survives.
	src2 := blockText(code)
	if !strings.Contains(src2, "fmt.Println(\"hi\")") || !strings.Contains(src2, "\tindented := true") {
		t.Errorf("code source lost content/indentation: %q", src2)
	}
}

func TestMarkdownBlocksUnterminatedFence(t *testing.T) {
	// A fence with no closer runs to EOF — honest, never an error.
	blocks := MarkdownBlocks("```\nline one\nline two")
	if len(blocks) != 1 || blocks[0].Type != "code" {
		t.Fatalf("→ %#v, want one code block", blocks)
	}
	if src := blockText(blocks[0]); src != "line one\nline two" {
		t.Errorf("code source = %q", src)
	}
}

func TestMarkdownBlocksNoLanguage(t *testing.T) {
	blocks := MarkdownBlocks("```\nplain\n```")
	if len(blocks) != 1 || blocks[0].Type != "code" {
		t.Fatalf("→ %#v, want one code block", blocks)
	}
	if _, ok := blocks[0].Attrs["language"]; ok {
		t.Errorf("no-language fence should omit the language attr")
	}
}

func TestMarkdownBlocksDegradesUnknown(t *testing.T) {
	// Blockquotes, tables, and other unhandled markdown become paragraph text
	// (charter D16: never lose content, never error).
	for _, src := range []string{"> a quotation", "| a | b |\n| - | - |", "1. ordered item", "* star bullet"} {
		blocks := MarkdownBlocks(src)
		for _, b := range blocks {
			if b.Type != "paragraph" {
				t.Errorf("%q produced a %q block, want only paragraphs (degrade)", src, b.Type)
			}
		}
	}
}

func TestMarkdownBlocksMixedDocument(t *testing.T) {
	src := "# Heading\n\nA paragraph of prose.\n\n- one\n- two\n\n```sh\necho hi\n```\n\nclosing words"
	blocks := MarkdownBlocks(src)
	wantTypes := []string{"heading", "paragraph", "list", "code", "paragraph"}
	if len(blocks) != len(wantTypes) {
		t.Fatalf("got %d blocks, want %d: %#v", len(blocks), len(wantTypes), blocks)
	}
	for i, wt := range wantTypes {
		if blocks[i].Type != wt {
			t.Errorf("block %d type = %q, want %q", i, blocks[i].Type, wt)
		}
	}
}

// TestMarkdownBlocksRendersThroughPdrender is the end-to-end no-panic guarantee:
// every block MarkdownBlocks emits renders through the real registry the detail
// view uses. A crash here would take the whole reading view down.
func TestMarkdownBlocksRendersThroughPdrender(t *testing.T) {
	reg := pdrender.DefaultRegistry(pdrender.DarkTheme())
	srcs := []string{
		"# Title\n\nbody text\n\n- a\n- b\n\n```go\nx := 1\n```",
		"just a plain sentence",
		"> quote\n| t | a |\n#nospace\n####### deep",
		"```\nunterminated",
		"",
	}
	for _, src := range srcs {
		blocks := MarkdownBlocks(src)
		// Must not panic; output may be empty for empty source.
		out := reg.RenderDoc(blocks, pdrender.RenderCtx{Width: 60, Profile: pdrender.TrueColor})
		_ = out
	}
}

// TestMarkdownBlocksNeverPanics fuzzes a handful of pathological inputs.
func TestMarkdownBlocksNeverPanics(t *testing.T) {
	inputs := []string{
		"```", "```\n```", "-", "- ", "#", "###### ", "\x1b[2J danger",
		strings.Repeat("- item\n", 200), strings.Repeat("#", 50) + " x",
	}
	for _, src := range inputs {
		_ = MarkdownBlocks(src) // a panic fails the test by crashing it
	}
}
