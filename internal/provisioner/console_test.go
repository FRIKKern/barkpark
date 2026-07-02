package provisioner

import (
	"context"
	"strings"
	"sync"
	"testing"
)

// consoleRec records every console line ProvisionWith tees (dwb-16). Its Report
// ALWAYS returns an error to prove the failure is SWALLOWED — a broken control
// plane must never fail a provision (console narration is pure telemetry).
type consoleRec struct {
	mu    sync.Mutex
	lines []string
}

func (c *consoleRec) Report(_ context.Context, _ /*jobID*/, line string) error {
	c.mu.Lock()
	c.lines = append(c.lines, line)
	c.mu.Unlock()
	return errString("control plane unreachable (simulated)")
}

func (c *consoleRec) joined() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return strings.Join(c.lines, "\n")
}

func (c *consoleRec) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.lines)
}

// TestRedactConsoleLine proves the console redactor scrubs a minted admin bearer
// (pattern), a secret-shaped env assignment (pattern), and a registered literal
// secret — the three ways a secret could reach a console line.
func TestRedactConsoleLine(t *testing.T) {
	got := redactConsoleLine("installing with bp_admin_ABC123def-_ and SECRET_KEY_BASE=hunter2 now", nil)
	if strings.Contains(got, "bp_admin_ABC123def-_") {
		t.Errorf("admin-token pattern not redacted: %q", got)
	}
	if strings.Contains(got, "hunter2") {
		t.Errorf("SECRET_KEY_BASE value not redacted: %q", got)
	}
	if !strings.Contains(got, "SECRET_KEY_BASE=[REDACTED]") {
		t.Errorf("SECRET_KEY_BASE key should survive with a redacted value: %q", got)
	}

	// A registered literal secret (the value the worker actually knows).
	got2 := redactConsoleLine("body carried LITERALSECRET inline", []string{"LITERALSECRET"})
	if strings.Contains(got2, "LITERALSECRET") {
		t.Errorf("registered literal secret not redacted: %q", got2)
	}

	// DATABASE_URL userinfo-style env assignment is also caught by the env pattern.
	got3 := redactConsoleLine("DATABASE_URL=ecto://u:p@h/db failed", nil)
	if strings.Contains(got3, "ecto://u:p@h/db") {
		t.Errorf("DATABASE_URL value not redacted: %q", got3)
	}
}

// TestProvisionTeesRedactedConsoleAndSwallowsErrors (dwb-16) proves three things
// at once against the fakes: (1) the create→live chain + content bootstrap
// narration is TEED to the console reporter (create…ready phases + the bootstrap
// sub-steps); (2) every teed line is REDACTED — the minted admin token and an
// env-secret the bootstrap echoes never appear; and (3) a ConsoleReporter that
// FAILS on every call does NOT fail the provision (it still returns a live IP).
// Non-vacuous: the reporter errors each time AND the bootstrap deliberately emits
// the raw admin token, yet ProvisionWith succeeds and no secret leaks.
func TestProvisionTeesRedactedConsoleAndSwallowsErrors(t *testing.T) {
	seams, _, _, _ := fakeSeams()
	rec := &consoleRec{}
	seams.ConsoleReporter = rec.Report
	// A fake bootstrap that narrates via ConsoleSink, deliberately echoing the
	// per-instance admin token + a secret-shaped env line to exercise redaction on
	// the bootstrap-teed console path.
	seams.Bootstrap = func(_ context.Context, req BootstrapRequest) (*BootstrapOutputs, error) {
		if req.ConsoleSink != nil {
			req.ConsoleSink("seeding content, admin=" + req.AdminToken)
			req.ConsoleSink("SECRET_KEY_BASE=supersecretvalue sourced")
		}
		return &BootstrapOutputs{Template: "blog", Workspace: "acme"}, nil
	}

	job := JobSpec{JobID: "job-console", Name: "Acme Co", Slug: "acme", Region: "nbg1", ServerType: "cax11", Template: "blog"}
	ip, adminToken, boot, teardown, err := ProvisionWith(context.Background(), seams, job)
	if err != nil {
		t.Fatalf("ProvisionWith failed despite console reporting being pure telemetry: %v", err)
	}
	if ip == "" || teardown == nil || boot == nil {
		t.Fatalf("ProvisionWith returned ip=%q teardown=%v boot=%v, want a live IP + teardown + bootstrap", ip, teardown, boot)
	}
	if rec.count() == 0 {
		t.Fatal("no console lines were teed; the /new console panel would be empty")
	}

	joined := rec.joined()

	// The phase transitions reached the console (human-readable narration).
	for _, want := range []string{"create: started", "ready: done"} {
		if !strings.Contains(joined, want) {
			t.Errorf("console did not carry %q; got:\n%s", want, joined)
		}
	}

	// REDACTION: neither the minted admin token nor the env-secret value leaked.
	if adminToken == "" || !strings.HasPrefix(adminToken, "bp_admin_") {
		t.Fatalf("expected a bp_admin_ token to assert redaction against, got %q", adminToken)
	}
	if strings.Contains(joined, adminToken) {
		t.Errorf("console LEAKED the minted admin token; got:\n%s", joined)
	}
	if strings.Contains(joined, "bp_admin_") {
		t.Errorf("console carried a bp_admin_ substring (pattern redaction missed it); got:\n%s", joined)
	}
	if strings.Contains(joined, "supersecretvalue") {
		t.Errorf("console LEAKED a SECRET_KEY_BASE value; got:\n%s", joined)
	}
}
