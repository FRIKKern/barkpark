package pdrender

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// fieldBlock is a small field-* block builder for the group tests.
func fieldBlock(ty, label, value string) Block {
	return Block{Type: ty, Attrs: map[string]any{"label": label, "value": value}}
}

// TestFieldGroupAligns is the definition-list guarantee: a run of consecutive
// field blocks renders with EVERY value starting at the same column — the label
// column is shared, not per-field. Measured ANSI-aware. This is the density fix;
// a regression to per-field two-line stacks would break the shared offset.
func TestFieldGroupAligns(t *testing.T) {
	reg := testRegistry()
	blocks := []Block{
		fieldBlock("field-string", "Title", "Hello"),
		fieldBlock("field-slug", "Slug", "hello"),
		fieldBlock("field-datetime", "Published at", "2026-05-24T10:00"),
		fieldBlock("field-boolean", "Featured", "false"),
	}
	out := ansi.Strip(reg.RenderDoc(blocks, RenderCtx{Width: 60, Theme: DarkTheme(), Profile: NoColor}))
	lines := strings.Split(out, "\n")

	// The value column offset = index of the value text on the widest-label row.
	// "Published at" (12) sets the label column; every value must start at the
	// same column. We find each row's value by its known value text.
	want := map[string]string{"Title": "Hello", "Slug": "hello", "Published at": "2026-05-24 10:00", "Featured": "No"}
	col := -1
	for _, ln := range lines {
		for label, val := range want {
			if strings.HasPrefix(strings.TrimRight(ln, " "), label) && strings.Contains(ln, val) {
				c := strings.Index(ln, val)
				if col == -1 {
					col = c
				} else if c != col {
					t.Errorf("value column misaligned: %q starts at %d, want %d\nrow: %q", val, c, col, ln)
				}
			}
		}
	}
	if col == -1 {
		t.Fatal("no field rows found — the group did not render")
	}
	// Non-vacuous: the shared column must clear the widest label ("Published at"
	// = 12) plus the gap, so a per-field stack (col 0) would fail this.
	if col < 12 {
		t.Fatalf("value column %d does not clear the widest label (12) — labels not aligned into a column", col)
	}
}

// TestFieldGroupSingleField proves a lone field still renders (label + value on
// one line) — the group path must handle N=1 without a panic or a blank.
func TestFieldGroupSingleField(t *testing.T) {
	reg := testRegistry()
	out := ansi.Strip(reg.RenderDoc([]Block{fieldBlock("field-string", "Name", "Ada")},
		RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}))
	if !strings.Contains(out, "Name") || !strings.Contains(out, "Ada") {
		t.Fatalf("single field lost its label or value: %q", out)
	}
}
