package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The wikilink task-chip seam (lvw-t7, wire §4/§5): TaskResolver turns a
// wikilink whose target is a TASK into the live status chip; everything else
// (nil resolver, nil chip, unresolved) degrades through the ordered
// alias → children → target label — never a crash, never a blank.

// chipDoc renders one paragraph holding a single wikilink node through the
// pinned-NoColor registry and returns the ANSI-stripped text.
func chipDoc(t *testing.T, node map[string]any, resolver func(id string) *TaskChip) string {
	t.Helper()
	reg := testRegistry()
	blocks := []Block{{
		ID:    "b1",
		Type:  "paragraph",
		Attrs: map[string]any{"content": []any{node}},
	}}
	ctx := RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor, TaskResolver: resolver}
	return ansi.Strip(reg.RenderDoc(blocks, ctx))
}

func TestTaskChipFullAnatomy(t *testing.T) {
	node := map[string]any{
		"type":     "wikilink",
		"target":   "lvw-t7",
		"docId":    "lvw-t7",
		"alias":    "the resolver task",
		"children": []any{},
	}
	resolver := func(id string) *TaskChip {
		if id != "lvw-t7" {
			t.Fatalf("resolver called with %q, want the pinned docId", id)
		}
		return &TaskChip{
			Title: "Type-aware resolver", Status: "open",
			Priority: 1, HasPriority: true,
			CriteriaMet: 2, CriteriaTotal: 5,
		}
	}
	out := chipDoc(t, node, resolver)
	if !strings.Contains(out, "[○ open · P1 · 2/5]") {
		t.Fatalf("chip anatomy missing, got: %q", out)
	}
	if !strings.Contains(out, "Type-aware resolver") {
		t.Fatalf("chip must be followed by the resolved title, got: %q", out)
	}
}

func TestTaskChipPriorityZeroIsValidHighest(t *testing.T) {
	node := map[string]any{"type": "wikilink", "target": "t-1", "docId": "t-1", "children": []any{}}
	out := chipDoc(t, node, func(string) *TaskChip {
		return &TaskChip{Title: "Urgent", Status: "in_progress", Priority: 0, HasPriority: true}
	})
	if !strings.Contains(out, "◐ in_progress · P0") {
		t.Fatalf("P0 (highest) must render, got: %q", out)
	}
}

func TestTaskChipCriteriaAbsentOmitsSegmentNeverZeroZero(t *testing.T) {
	node := map[string]any{"type": "wikilink", "target": "t-1", "docId": "t-1", "children": []any{}}
	out := chipDoc(t, node, func(string) *TaskChip {
		return &TaskChip{Title: "No criteria", Status: "open", Priority: 2, HasPriority: true}
	})
	if strings.Contains(out, "0/0") {
		t.Fatalf("criteria-absent must OMIT the m/n segment, never 0/0: %q", out)
	}
	if !strings.Contains(out, "[○ open · P2]") {
		t.Fatalf("chip should carry status + priority only, got: %q", out)
	}
}

func TestTaskChipUnknownStatusGetsNeutralGlyph(t *testing.T) {
	node := map[string]any{"type": "wikilink", "target": "t-1", "docId": "t-1", "children": []any{}}
	out := chipDoc(t, node, func(string) *TaskChip {
		return &TaskChip{Title: "Weird", Status: "someday"}
	})
	if !strings.Contains(out, "▸ someday") {
		t.Fatalf("unknown status must keep the neutral glyph + text, got: %q", out)
	}
}

// Nil resolver + a CHILDLESS aliased wikilink: the ordered alias fallback must
// produce VISIBLE text (this node rendered as an empty string before lvw-t7 —
// asserting visible output keeps the test non-vacuous).
func TestWikilinkNilResolverChildlessAliasVisible(t *testing.T) {
	node := map[string]any{
		"type":     "wikilink",
		"target":   "lvw-t7",
		"docId":    "lvw-t7",
		"alias":    "the resolver task",
		"children": []any{},
	}
	out := chipDoc(t, node, nil)
	if !strings.Contains(out, "the resolver task") {
		t.Fatalf("childless aliased wikilink must show the alias, got: %q", out)
	}
}

// Resolver present but returns nil (target is not a task): same visible
// alias degrade — the chip branch must not eat the node.
func TestWikilinkResolverNilChipDegradesToAlias(t *testing.T) {
	node := map[string]any{
		"type":     "wikilink",
		"target":   "Some Paper",
		"alias":    "a paper link",
		"children": []any{},
	}
	out := chipDoc(t, node, func(string) *TaskChip { return nil })
	if !strings.Contains(out, "a paper link") {
		t.Fatalf("nil chip must degrade to the alias label, got: %q", out)
	}
}

// Childless, alias-less wikilink: the final target fallback must be visible.
func TestWikilinkChildlessNoAliasFallsBackToTarget(t *testing.T) {
	node := map[string]any{"type": "wikilink", "target": "Orphan Target", "children": []any{}}
	out := chipDoc(t, node, nil)
	if !strings.Contains(out, "Orphan Target") {
		t.Fatalf("childless alias-less wikilink must show the target, got: %q", out)
	}
}

// Resolver output is untrusted: control bytes in title/status must be
// stripped by sanitizeText before display. Deliberately asserted on the RAW
// render (no ansi.Strip — stripping would eat a leaked ESC and pass
// vacuously); the registry pins lipgloss to Ascii, so any escape byte in the
// output can only have leaked from the resolver strings.
func TestTaskChipSanitizesResolverOutput(t *testing.T) {
	node := map[string]any{"type": "wikilink", "target": "t-1", "docId": "t-1", "children": []any{}}
	reg := testRegistry()
	blocks := []Block{{
		ID:    "b1",
		Type:  "paragraph",
		Attrs: map[string]any{"content": []any{node}},
	}}
	resolver := func(string) *TaskChip {
		return &TaskChip{Title: "Ti\x1btle\x07", Status: "op\x1ben"}
	}
	raw := reg.RenderDoc(blocks, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor, TaskResolver: resolver})
	// The theme itself may emit \x1b[...m SGR sequences; the LEAK signatures are
	// the BEL byte and the bare ESC directly followed by the title's 't' (an
	// unsanitized "Ti\x1btle" keeps that byte pair verbatim inside the label).
	if strings.Contains(raw, "\x07") || strings.Contains(raw, "\x1bt") {
		t.Fatalf("resolver strings must pass sanitizeText, got: %q", raw)
	}
	stripped := ansi.Strip(raw)
	if !strings.Contains(stripped, "Title") || !strings.Contains(stripped, "open") {
		t.Fatalf("sanitized text should keep the printable runes, got: %q", stripped)
	}
}

// A chip with an empty title falls back to the node's alias label — the chip
// never blanks its right-hand side.
func TestTaskChipEmptyTitleFallsBackToAlias(t *testing.T) {
	node := map[string]any{
		"type":     "wikilink",
		"target":   "t-1",
		"docId":    "t-1",
		"alias":    "chip alias",
		"children": []any{},
	}
	out := chipDoc(t, node, func(string) *TaskChip {
		return &TaskChip{Status: "done"}
	})
	if !strings.Contains(out, "● done") || !strings.Contains(out, "chip alias") {
		t.Fatalf("empty-title chip must fall back to the alias label, got: %q", out)
	}
}
