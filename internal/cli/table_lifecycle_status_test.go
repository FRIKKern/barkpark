package cli

import (
	"bytes"
	"strings"
	"testing"
)

// TestStatusRoleTaskLifecycle proves the shared semrole vocabulary reaches the
// CLI table seam: after delegating statusRole to internal/semrole, task
// lifecycle tokens map to the same four roles as cloud/deploy tokens — so
// `bp task … -o table` colours its lifecycle cells for free, no per-command
// wiring. ready/open/cancelled stay neutral ("").
func TestStatusRoleTaskLifecycle(t *testing.T) {
	cases := map[string]string{
		"in_progress": "info",
		"blocked":     "warn",
		"done":        "ok",
		"closed":      "ok",
		"ready":       "",
		"open":        "",
		"cancelled":   "",
	}
	for in, want := range cases {
		if got := statusRole(in); got != want {
			t.Errorf("statusRole(%q) = %q, want %q", in, got, want)
		}
	}
}

// taskTablePayload mimics a `bp task ready -o table` envelope: the tasks
// endpoints carry rows under "docs", and each doc has a lifecycle_status cell.
const taskTablePayload = `{"docs":[` +
	`{"id":"t1","title":"Ship it","lifecycle_status":"in_progress"},` +
	`{"id":"t2","title":"Wait","lifecycle_status":"blocked"},` +
	`{"id":"t3","title":"Grab","lifecycle_status":"ready"},` +
	`{"id":"t4","title":"Filed","lifecycle_status":"done"}` +
	`]}`

// TestTaskTableColorsLifecycleCells: with color ON at the basic-16 floor, a task
// list's lifecycle_status cells are painted by role — in_progress BLUE (info, the
// S6 retint from cyan), blocked yellow (warn), done green (the ok floor: the teal
// lifecycle hue only survives at 256/truecolor, proven by
// TestPaintCellLifecycleTealTrueColor) — while a neutral "ready" cell stays
// unpainted. This is the end-to-end proof the delegation lights up the task board's
// table view down the whole ladder. The writer carries no bound renderer, so
// paintCell degrades to the pinned semrole.GenANSI16 floor (deterministic).
func TestTaskTableColorsLifecycleCells(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.color = true
	renderTable(w, []byte(taskTablePayload))
	got := stdout.String()

	if !strings.Contains(got, "\x1b[34m"+"in_progress") {
		t.Errorf("expected blue (info) in_progress; got:\n%q", got)
	}
	if !strings.Contains(got, "\x1b[33m"+"blocked") {
		t.Errorf("expected yellow (warn) blocked; got:\n%q", got)
	}
	if !strings.Contains(got, "\x1b[32m"+"done") {
		t.Errorf("expected green (ok floor) done; got:\n%q", got)
	}
	// A neutral lifecycle cell (ready carries a hue but no status role) must NOT be
	// wrapped in any colour span at the 16 floor.
	if strings.Contains(got, "\x1b[34m"+"ready") ||
		strings.Contains(got, "\x1b[36m"+"ready") ||
		strings.Contains(got, "\x1b[33m"+"ready") ||
		strings.Contains(got, "\x1b[32m"+"ready") ||
		strings.Contains(got, "\x1b[31m"+"ready") {
		t.Errorf("neutral 'ready' cell must be unpainted; got:\n%q", got)
	}
}
