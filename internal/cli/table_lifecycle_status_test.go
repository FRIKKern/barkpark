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

// TestTaskTableColorsLifecycleCells: with color ON, a task list's
// lifecycle_status cells are painted by role — in_progress cyan (info), blocked
// yellow (warn), done green (ok) — while a neutral "ready" cell stays unpainted.
// This is the end-to-end proof the #979 delegation lights up the task board's
// table view.
func TestTaskTableColorsLifecycleCells(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.color = true
	renderTable(w, []byte(taskTablePayload))
	got := stdout.String()

	if !strings.Contains(got, "\x1b[36m"+"in_progress") {
		t.Errorf("expected cyan (info) in_progress; got:\n%q", got)
	}
	if !strings.Contains(got, "\x1b[33m"+"blocked") {
		t.Errorf("expected yellow (warn) blocked; got:\n%q", got)
	}
	if !strings.Contains(got, "\x1b[32m"+"done") {
		t.Errorf("expected green (ok) done; got:\n%q", got)
	}
	// A neutral lifecycle cell must NOT be wrapped in any color span.
	if strings.Contains(got, "\x1b[36m"+"ready") ||
		strings.Contains(got, "\x1b[33m"+"ready") ||
		strings.Contains(got, "\x1b[32m"+"ready") ||
		strings.Contains(got, "\x1b[31m"+"ready") {
		t.Errorf("neutral 'ready' cell must be unpainted; got:\n%q", got)
	}
}
