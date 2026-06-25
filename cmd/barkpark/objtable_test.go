package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Object-array table pins (2026-06-12): homogeneous flat-object arrays render
// as an aligned mini-table; anything non-conforming keeps the JSON fallback —
// the table never guesses.

func TestObjectTableShapes(t *testing.T) {
	rows, ok := objectTable(json.RawMessage(`[
		{"sku":"A-1","qty":3,"live":true},
		{"sku":"B-22","qty":14,"live":false}
	]`), 60)
	if !ok {
		t.Fatal("flat-object array should table")
	}
	joined := strings.Join(rows, "\n")
	for _, want := range []string{"SKU", "QTY", "LIVE", "A-1", "B-22", "14", "false"} {
		if !strings.Contains(joined, want) {
			t.Errorf("table missing %q:\n%s", want, joined)
		}
	}
	// Header + 2 rows, no more-line.
	if len(rows) != 3 {
		t.Errorf("want 3 lines, got %d:\n%s", len(rows), joined)
	}

	// Refusals: nested values, mixed non-objects, scalars, empty.
	for name, raw := range map[string]string{
		"nested":     `[{"a":{"b":1}}]`,
		"mixed":      `[{"a":1},"loose-string"]`,
		"scalar":     `"just-a-string"`,
		"empty":      `[]`,
		"string-arr": `["a","b"]`,
	} {
		if _, ok := objectTable(json.RawMessage(raw), 60); ok {
			t.Errorf("%s should NOT table", name)
		}
	}
}

func TestObjectTableClampsRowsAndWidth(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("[")
	for i := 0; i < 9; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`{"name":"row-with-a-rather-long-value","n":` + string(rune('0'+i)) + `}`)
	}
	sb.WriteString("]")

	rows, ok := objectTable(json.RawMessage(sb.String()), 30)
	if !ok {
		t.Fatal("should table")
	}
	if !strings.Contains(rows[len(rows)-1], "+3 more rows") {
		t.Errorf("9 rows should clamp at 6 with a more-line:\n%s", strings.Join(rows, "\n"))
	}
	for _, r := range rows {
		if lipgloss.Width(r) > 30 {
			t.Errorf("row exceeds width budget (%d cols): %q", lipgloss.Width(r), r)
		}
	}
}

func TestStructuredFieldBodyPrefersTable(t *testing.T) {
	m := model{
		selectedDoc: &Doc{ID: "t1", Extra: map[string]json.RawMessage{
			"deps":  json.RawMessage(`[{"id":"a","done":true},{"id":"b","done":false}]`),
			"claim": json.RawMessage(`{"worker":"w","epoch":3}`),
		}},
		editorSchema: &apiclient.Schema{Name: "task"},
		width:        100, height: 40,
	}

	body, ok := m.structuredFieldBody("deps", 60)
	if !ok || !strings.Contains(body, "ID") || !strings.Contains(body, "DONE") {
		t.Errorf("deps should table:\n%s", body)
	}
	// A plain object keeps the JSON fallback.
	body, ok = m.structuredFieldBody("claim", 60)
	if !ok || !strings.Contains(body, `"worker"`) {
		t.Errorf("claim should stay pretty JSON:\n%s", body)
	}
	// Absent field reports no data.
	if _, ok := m.structuredFieldBody("nope", 60); ok {
		t.Error("absent field should report no data")
	}
}
