package provisioner

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// consoleRec records every console line ProvisionWith tees (dwb-16). Its Report
// fails the FIRST call (to prove the error is SWALLOWED — a broken control plane
// must never fail a provision) then succeeds, so the consecutive-failure latch
// (maxConsoleFails) never engages and EVERY narration line still tees — the
// redaction assertions below need the late bootstrap lines. The all-failing latch
// path is covered directly by TestConsoleEmitterLatchesAfterMaxFails.
type consoleRec struct {
	mu    sync.Mutex
	lines []string
	calls int
}

func (c *consoleRec) Report(_ context.Context, _ /*jobID*/, line string) error {
	c.mu.Lock()
	c.lines = append(c.lines, line)
	c.calls++
	first := c.calls == 1
	c.mu.Unlock()
	if first {
		return errString("control plane unreachable (simulated)")
	}
	return nil
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

	// dwb-20: the per-instance BARKPARK_KEK (and its rotation companion) must be
	// scrubbed the same way — a shared/logged KEK is the cross-tenant hole this task
	// closes, so the console path can never carry its value.
	gotKEK := redactConsoleLine("sealing BARKPARK_KEK=kekVALUE0000 and BARKPARK_KEK_PREVIOUS=oldKEK1111 done", nil)
	for _, leaked := range []string{"kekVALUE0000", "oldKEK1111"} {
		if strings.Contains(gotKEK, leaked) {
			t.Errorf("BARKPARK_KEK value not redacted: %q", gotKEK)
		}
	}
	for _, kept := range []string{"BARKPARK_KEK=[REDACTED]", "BARKPARK_KEK_PREVIOUS=[REDACTED]"} {
		if !strings.Contains(gotKEK, kept) {
			t.Errorf("KEK key should survive with a redacted value: %q", gotKEK)
		}
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

// TestRedactConsoleLine_GenericSecretShapes is the proven-able-to-fail arm for
// the console redactor's move off its six-name allowlist.
//
// BEFORE: redactConsoleLine ran envSecretConsoleRe, the literal alternation
// (SECRET_KEY_BASE|BARKPARK_KEK_PREVIOUS|BARKPARK_KEK|BARKPARK_CLOAK_KEY|
// PREVIEW_JWT_SECRET|DATABASE_URL), plus adminTokenRe (bp_admin_ ONLY) — and no
// Bearer or ecto-userinfo clause at all. Run against that code this test fails
// on FIVE of the six values below: only the DATABASE_URL assignment was caught.
// Every one of them lands in the persisted, rendered provision_jobs.console.
//
// AFTER: the redaction is secretscrub.Line, shared with the SSH step runner and
// the builder console, and all six redact.
//
// Every value here is synthetic — no real credential appears in this repo.
func TestRedactConsoleLine_GenericSecretShapes(t *testing.T) {
	in := "bootstrap narration: ANTHROPIC_API_KEY=sk-ant-synthetic0000000000 " +
		"FLEET_LISTENER_TOKEN=synthetictoken1111111111 " +
		"PGPASSWORD=syntheticpassword22222222 " +
		"handle bp_read_syntheticREADTOKEN333 " +
		"dsn ecto://u:syntheticPASS4444@h/db " +
		"Authorization: Bearer syntheticbearer55555555"
	got := redactConsoleLine(in, nil)

	for _, leaked := range []string{
		"sk-ant-synthetic0000000000",
		"synthetictoken1111111111",
		"syntheticpassword22222222",
		"bp_read_syntheticREADTOKEN333",
		"syntheticPASS4444",
		"syntheticbearer55555555",
	} {
		if strings.Contains(got, leaked) {
			t.Errorf("the console redactor leaked %q into provision_jobs.console; got:\n%s", leaked, got)
		}
	}
	// The KEY NAMES survive so a failed provision stays diagnosable.
	for _, kept := range []string{
		"ANTHROPIC_API_KEY=[REDACTED]",
		"FLEET_LISTENER_TOKEN=[REDACTED]",
		"PGPASSWORD=[REDACTED]",
		"Bearer [REDACTED]",
		"ecto://[REDACTED]@h/db",
	} {
		if !strings.Contains(got, kept) {
			t.Errorf("the console redactor dropped expected marker %q; got:\n%s", kept, got)
		}
	}
}

// TestRedactConsoleLine_KeepsKeyHandoffInstruction pins the ONE named
// non-defect against the console path specifically. (*supportRun).verifyRuntime
// narrates the PDF-D88 provider-key hand-off one-liner THROUGH redactConsoleLine
// — a developer has to read and paste it. The six-name allowlist never matched
// ANTHROPIC_API_KEY, so widening to a shape match is exactly the change that
// could have destroyed the instruction; secretscrub's placeholder guard is what
// stops it, and this asserts it on the real emitter's format string rather than
// a copy.
func TestRedactConsoleLine_KeepsKeyHandoffInstruction(t *testing.T) {
	line := fmt.Sprintf("agent provider keys are NEVER copied — hand the box its %s key yourself: ssh root@%s \"printf '%s=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\"",
		"claude", "203.0.113.9", "ANTHROPIC_API_KEY")
	if got := redactConsoleLine(line, nil); got != line {
		t.Errorf("the key hand-off instruction was mangled by the console redactor:\n want: %s\n  got: %s", line, got)
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
	seams, _, _, _ := fakeSeams(t)
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

// TestConsoleEmitterLatchesAfterMaxFails proves the fail-latch: an always-erroring
// reporter is called at most maxConsoleFails times across many logf calls, so a
// down control plane can't burn a full report timeout on every remaining line of
// the provision. 10 logf calls → exactly maxConsoleFails (3) report invocations.
func TestConsoleEmitterLatchesAfterMaxFails(t *testing.T) {
	calls := 0
	report := func(_ context.Context, _, _ string) error {
		calls++
		return errString("control plane unreachable")
	}
	c := newConsoleEmitter(context.Background(), "job-latch", report)
	for i := 0; i < 10; i++ {
		c.logf("narration line %d", i)
	}
	if calls != maxConsoleFails {
		t.Fatalf("expected exactly %d report calls before the latch, got %d", maxConsoleFails, calls)
	}
}

// TestConsoleEmitterSuccessResetsLatch proves a single success resets the
// consecutive-failure counter, so a transient blip never permanently latches
// narration off: two fails, one success, then a fresh run of fails must take the
// FULL maxConsoleFails again to re-latch.
func TestConsoleEmitterSuccessResetsLatch(t *testing.T) {
	calls := 0
	fail := true
	report := func(_ context.Context, _, _ string) error {
		calls++
		if fail {
			return errString("control plane unreachable")
		}
		return nil
	}
	c := newConsoleEmitter(context.Background(), "job-reset", report)
	c.logf("a") // fail → fails=1
	c.logf("b") // fail → fails=2
	fail = false
	c.logf("c") // success → fails reset to 0
	fail = true
	for i := 0; i < 10; i++ {
		c.logf("d%d", i) // three more fails re-latch, the rest are skipped
	}
	// 2 (initial fails) + 1 (success) + maxConsoleFails (re-latch) reported calls.
	want := 2 + 1 + maxConsoleFails
	if calls != want {
		t.Fatalf("expected %d report calls (reset then re-latch), got %d", want, calls)
	}
}
