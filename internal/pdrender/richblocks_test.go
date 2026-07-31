package pdrender

import (
	"strings"
	"testing"
)

// TestPdTableNeverPanic asserts the table renderer degrades gracefully on empty
// and degenerate inputs. A `table` block whose rows decode to empty arrays (no
// head) yields a zero-column table; lipgloss/table's auto-sizer indexes
// colWidths[0] on that and panics (index out of range), which previously took
// down the entire RenderDoc — a document-controlled block crashing the whole
// TUI/CLI viewer. The guard in tableRenderer.Render skips zero-column rows and
// returns empty output when there are no columns at all.
func TestPdTableNeverPanic(t *testing.T) {
	reg := testRegistry()
	cases := []Block{
		{Type: "table", Attrs: map[string]any{}},
		{Type: "table", Attrs: map[string]any{"head": []any{}, "rows": []any{}}},
		{Type: "table", Attrs: map[string]any{"rows": []any{[]any{}}}},
		{Type: "table", Attrs: map[string]any{"rows": []any{[]any{}, []any{}}}},
	}
	for _, b := range cases {
		b := b
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("table panicked on degenerate input %v: %v", b.Attrs, r)
				}
			}()
			_ = reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
		}()
	}
}

// TestPdTableRendersNormally is a sanity check that the empty-row guard does not
// disturb a well-formed table: a head plus one empty row still renders the head.
func TestPdTableRendersNormally(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "table",
		Attrs: map[string]any{
			"head": []any{"Name", "Score"},
			"rows": []any{
				[]any{"Alice", "42"},
				[]any{}, // stray empty row — skipped, must not panic or blank the table
				[]any{"Bob", "7"},
			},
		},
	}

	out := reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor})
	joined := ""
	for _, line := range out {
		joined += line + "\n"
	}

	for _, want := range []string{"NAME", "SCORE", "Alice", "Bob"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("expected rendered table to contain %q, got:\n%s", want, joined)
		}
	}
}

func TestPdTableRendersObjectWrappedRowsAndCells(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "table",
		Attrs: map[string]any{
			"rows": []any{
				map[string]any{"header": true, "cells": []any{
					map[string]any{"content": []any{map[string]any{"type": "text", "value": "Name"}}},
				}},
				map[string]any{"cells": []any{
					map[string]any{"content": []any{map[string]any{"type": "text", "value": "Ada"}}},
				}},
			},
		},
	}

	out := strings.Join(reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n")
	for _, want := range []string{"NAME", "Ada"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected wrapped table to contain %q, got:\n%s", want, out)
		}
	}
}

func TestPdCalloutRendersLegacyTextBody(t *testing.T) {
	reg := testRegistry()
	b := Block{Type: "callout", Attrs: map[string]any{"text": "Visible body"}}
	out := strings.Join(reg.Render(b, RenderCtx{Width: 40, Theme: DarkTheme(), Profile: NoColor}), "\n")
	if !strings.Contains(out, "Visible body") {
		t.Fatalf("expected legacy callout text to remain visible, got:\n%s", out)
	}
}

func TestPdEyebrowDropsLetterSpacingWhenItWouldWrap(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "eyebrow",
		Attrs: map[string]any{
			"text": "Jarl website programme charter live — the board at the end is the real epic tree",
		},
	}

	out := strings.Join(reg.Render(b, RenderCtx{Width: 80, Theme: DarkTheme(), Profile: NoColor}), "\n")
	if strings.Contains(out, "J A R L") {
		t.Fatalf("long eyebrow should drop decorative letter spacing at width 80, got:\n%s", out)
	}
	if !strings.Contains(out, "JARL WEBSITE PROGRAMME") {
		t.Fatalf("long eyebrow should remain readable and uppercase, got:\n%s", out)
	}
}

func TestPdTableRendersDeclaredRecordRows(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "table",
		Attrs: map[string]any{
			"columns": []any{
				map[string]any{"key": "k", "label": "Key"},
				map[string]any{"key": "why", "label": "Why"},
			},
			"rows": []any{map[string]any{"k": "A", "why": "Because"}},
		},
	}
	out := strings.Join(reg.Render(b, RenderCtx{Width: 50, Theme: DarkTheme(), Profile: NoColor}), "\n")
	for _, want := range []string{"KEY", "WHY", "A", "Because"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected record table to contain %q, got:\n%s", want, out)
		}
	}
}

func TestPdTableRendersTextWrappedColumnsAndCells(t *testing.T) {
	reg := testRegistry()
	b := Block{
		Type: "table",
		Attrs: map[string]any{
			"columns": []any{
				map[string]any{"text": "Surface"},
				map[string]any{"text": "Proof"},
			},
			"rows": []any{[]any{
				map[string]any{"text": "CLI"},
				map[string]any{"text": "visible"},
			}},
		},
	}
	out := strings.Join(reg.Render(b, RenderCtx{Width: 50, Theme: DarkTheme(), Profile: NoColor}), "\n")
	for _, want := range []string{"SURFACE", "PROOF", "CLI", "visible"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expected text-wrapped table to contain %q, got:\n%s", want, out)
		}
	}
}
