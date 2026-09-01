package cloud

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
)

// ─── generic secret-shape scrubbing (worker-side, provision_jobs.error) ──────
//
// These tests cover the WORKER-SIDE redaction boundary: everything the SSH /
// real step runners capture from a remote box and wrap into an error, which the
// worker persists RAW into the provision_jobs.error column. The Elixir display
// boundary (FailureCopy) is a SECOND, independent scrub — it protects what a
// person reads, not what is stored. Storage is what these tests protect.

// fleetKeyHandoffFormat is a VERBATIM copy of the narration format string in
// internal/provisioner/support.go: the PDF-D88 key hand-off logf inside
// (*supportRun).verifyRuntime — the one line in that file carrying
// spec.keyVar. That line deliberately renders a provider key VAR NAME with a
// PLACEHOLDER value so a developer can copy the one-liner; it is the one named
// NON-defect the generic scrubber must not mangle.
// TestFleetKeyHandoffNarration_StillLivesInProvisioner is the tripwire that
// catches this copy going stale.
const fleetKeyHandoffFormat = "agent provider keys are NEVER copied — hand the box its %s key yourself: ssh root@%s \"printf '%s=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\""

// syntheticNarration is one line carrying every shape the six-name allowlist
// missed. EVERY value here is synthetic — no real credential appears in this
// repo's tests.
const syntheticNarration = "bootstrap failed on the box; captured remote output follows\n" +
	"ANTHROPIC_API_KEY=sk-ant-synthetic0000000000\n" +
	"FLEET_LISTENER_TOKEN=synthetictoken1111111111\n" +
	"PGPASSWORD=syntheticpassword22222222\n" +
	"leftover handle bp_read_syntheticREADTOKEN333 in the log\n" +
	"DATABASE_URL=ecto://u:syntheticPASS4444@h/db\n" +
	"Authorization: Bearer syntheticbearer55555555"

// TestScrubEnvSecrets_GenericShapes is the criterion-3 proof: the scrub is able
// to FAIL. Before the change, envSecretAssignRe was a hardcoded six-name
// allowlist (SECRET_KEY_BASE, BARKPARK_KEK{,_PREVIOUS}, BARKPARK_CLOAK_KEY,
// PREVIEW_JWT_SECRET, DATABASE_URL) and every value below except the
// DATABASE_URL one flowed through UNREDACTED into provision_jobs.error.
func TestScrubEnvSecrets_GenericShapes(t *testing.T) {
	out := scrubEnvSecrets(syntheticNarration)

	for _, leaked := range []string{
		"sk-ant-synthetic0000000000",
		"synthetictoken1111111111",
		"syntheticpassword22222222",
		"bp_read_syntheticREADTOKEN333",
		"syntheticPASS4444",
		"syntheticbearer55555555",
	} {
		if strings.Contains(out, leaked) {
			t.Errorf("scrubEnvSecrets leaked %q; got:\n%s", leaked, out)
		}
	}

	// The KEY NAMES survive so a failing provision is still diagnosable.
	for _, kept := range []string{
		"ANTHROPIC_API_KEY=[REDACTED]",
		"FLEET_LISTENER_TOKEN=[REDACTED]",
		"PGPASSWORD=[REDACTED]",
		"DATABASE_URL=[REDACTED]",
		"Bearer [REDACTED]",
	} {
		if !strings.Contains(out, kept) {
			t.Errorf("scrubEnvSecrets dropped expected marker %q; got:\n%s", kept, out)
		}
	}
}

// TestScrubEnvSecrets_KeepsLegacySixNameCoverage guards the ONE narrowing a
// naive port of internal/builder/console.go's builderEnvSecretRe would cause:
// BARKPARK_KEK and BARKPARK_KEK_PREVIOUS contain neither SECRET nor KEY (K-E-K,
// not K-E-Y), so the builder's alternation does NOT cover them. Dropping the
// six-name list without adding KEK to the shape alternation would SILENTLY stop
// redacting the key-encryption key during a rotation window.
func TestScrubEnvSecrets_KeepsLegacySixNameCoverage(t *testing.T) {
	in := "BARKPARK_KEK=syntheticKEKvalue0000\n" +
		"BARKPARK_KEK_PREVIOUS=syntheticOldKEK1111\n" +
		"BARKPARK_CLOAK_KEY=syntheticCloak2222\n" +
		"SECRET_KEY_BASE=syntheticBase3333\n" +
		"PREVIEW_JWT_SECRET=syntheticJwt4444\n" +
		"DATABASE_URL=ecto://u:syntheticPass5555@h/db"
	out := scrubEnvSecrets(in)

	for _, leaked := range []string{
		"syntheticKEKvalue0000", "syntheticOldKEK1111", "syntheticCloak2222",
		"syntheticBase3333", "syntheticJwt4444", "syntheticPass5555",
	} {
		if strings.Contains(out, leaked) {
			t.Errorf("scrubEnvSecrets leaked legacy-allowlist value %q; got:\n%s", leaked, out)
		}
	}
	// The LONGER key must win: BARKPARK_KEK_PREVIOUS keeps its full name rather
	// than being truncated to BARKPARK_KEK with a "_PREVIOUS=..." tail.
	for _, kept := range []string{
		"BARKPARK_KEK=[REDACTED]",
		"BARKPARK_KEK_PREVIOUS=[REDACTED]",
		"BARKPARK_CLOAK_KEY=[REDACTED]",
		"SECRET_KEY_BASE=[REDACTED]",
		"PREVIEW_JWT_SECRET=[REDACTED]",
		"DATABASE_URL=[REDACTED]",
	} {
		if !strings.Contains(out, kept) {
			t.Errorf("scrubEnvSecrets dropped expected marker %q; got:\n%s", kept, out)
		}
	}
}

// TestScrubEnvSecrets_PreservesPlaceholderInstruction is the criterion-4 trap.
// In internal/provisioner/support.go, the PDF-D88 key hand-off logf inside
// (*supportRun).verifyRuntime — the line carrying spec.keyVar — narrates a
// provider key VAR NAME with an angle-bracket PLACEHOLDER value. A generic
// ALLCAPS_KEY=value scrubber would mangle it into
// `ANTHROPIC_API_KEY=[REDACTED]` and destroy an instruction a developer has to
// be able to read and paste. The placeholder guard must let it through
// BYTE-FOR-BYTE.
func TestScrubEnvSecrets_PreservesPlaceholderInstruction(t *testing.T) {
	for _, keyVar := range []string{"ANTHROPIC_API_KEY", "OPENAI_API_KEY"} {
		line := fmt.Sprintf(fleetKeyHandoffFormat, "claude", "203.0.113.9", keyVar)
		if out := scrubEnvSecrets(line); out != line {
			t.Errorf("the %s hand-off instruction was mangled by the scrub:\n want: %s\n  got: %s", keyVar, line, out)
		}
		// And the readable part is genuinely intact, not merely equal by accident.
		if !strings.Contains(scrubEnvSecrets(line), keyVar+"=<your-key>") {
			t.Errorf("%s=<your-key> did not survive the scrub readable", keyVar)
		}
	}
}

// TestScrubEnvSecrets_PlaceholderGuardIsNarrow proves the guard is an exemption
// for an OBVIOUS placeholder only — it must not become a bypass. A value that
// merely STARTS with an angle-bracket group and then continues into real
// material is still a secret and is still redacted.
func TestScrubEnvSecrets_PlaceholderGuardIsNarrow(t *testing.T) {
	in := "SECRET_KEY_BASE=<x>syntheticSmuggled6666"
	out := scrubEnvSecrets(in)
	if strings.Contains(out, "syntheticSmuggled6666") {
		t.Errorf("the placeholder guard became a bypass — value smuggled through:\n%s", out)
	}
}

// TestScrubEnvSecrets_LeavesProseAlone re-asserts the scrub is a no-op on
// ordinary failure text now that the key match is shape-based rather than an
// explicit name list. Lowercase prose must never be mangled.
func TestScrubEnvSecrets_LeavesProseAlone(t *testing.T) {
	in := "migration 20260101 failed: relation \"posts\" already exists (key=value not secret)"
	if out := scrubEnvSecrets(in); out != in {
		t.Errorf("scrubEnvSecrets mangled clean output:\n in: %s\nout: %s", in, out)
	}
}

// TestScrubStepOutput_ScrubsStepWithoutRedactEnvSecrets is the criterion-1 arm
// that would have caught the filed defect: the pattern scrub used to be OPT-IN
// PER STEP (`if s.RedactEnvSecrets`), set at only 7 of the 15 non-test CaddyStep
// literals in this package. A step WITHOUT the flag funneled raw captured remote
// output straight into the wrapped error and on into provision_jobs.error. Raw
// captured remote output is never a place a secret is wanted, so the scrub now
// runs on EVERY step and no site opts out.
func TestScrubStepOutput_ScrubsStepWithoutRedactEnvSecrets(t *testing.T) {
	step := CaddyStep{
		Title: "enable + start the fleet listener", // a real flag-less step shape
		Argv:  []string{"bash", "-lc", "systemctl enable --now barkpark-fleet-listener"},
		// RedactEnvSecrets deliberately NOT set — that is the whole point.
	}
	out := scrubStepOutput(syntheticNarration, step)

	for _, leaked := range []string{
		"sk-ant-synthetic0000000000",
		"synthetictoken1111111111",
		"syntheticpassword22222222",
		"bp_read_syntheticREADTOKEN333",
		"syntheticPASS4444",
		"syntheticbearer55555555",
	} {
		if strings.Contains(out, leaked) {
			t.Errorf("a step with RedactEnvSecrets UNSET leaked %q into the step output; got:\n%s", leaked, out)
		}
	}
}

// TestSSHRunner_FlaglessStep_ScrubsCapturedOutput is the end-to-end half of the
// same arm: a FAILING step that never set RedactEnvSecrets must not carry the
// captured secrets into the error the worker persists.
func TestSSHRunner_FlaglessStep_ScrubsCapturedOutput(t *testing.T) {
	r := &SSHStepRunner{
		Host: "198.51.100.7",
		Key:  "/dev/null",
		Exec: func(_ context.Context, _ string, _ ...string) (string, error) {
			return syntheticNarration, fmt.Errorf("exit status 1")
		},
	}
	step := CaddyStep{
		Title: "enable + start the fleet listener",
		Argv:  []string{"bash", "-lc", "systemctl enable --now barkpark-fleet-listener"},
		// no Redact, no RedactEnvSecrets — the flag-less majority of steps
	}

	err := r.Run(context.Background(), step)
	if err == nil {
		t.Fatal("SSHStepRunner.Run: want an error for the failed step, got nil")
	}
	msg := err.Error()
	for _, leaked := range []string{
		"sk-ant-synthetic0000000000",
		"synthetictoken1111111111",
		"syntheticpassword22222222",
		"bp_read_syntheticREADTOKEN333",
		"syntheticPASS4444",
	} {
		if strings.Contains(msg, leaked) {
			t.Errorf("the wrapped error (bound for provision_jobs.error) leaked %q; got:\n%s", leaked, msg)
		}
	}
	if !strings.Contains(msg, "[REDACTED]") {
		t.Errorf("no [REDACTED] marker in the error — was anything scrubbed at all? got:\n%s", msg)
	}
}

// TestFleetKeyHandoffNarration_StillLivesInProvisioner is the anti-drift
// tripwire for fleetKeyHandoffFormat above: this package cannot import
// internal/provisioner (provisioner imports cloud), so the format string is a
// COPY. If the real narration is reworded or moved, this fails loudly rather
// than letting the placeholder-guard test silently guard a string nothing emits.
func TestFleetKeyHandoffNarration_StillLivesInProvisioner(t *testing.T) {
	src, err := os.ReadFile("../../provisioner/support.go")
	if err != nil {
		t.Fatalf("cannot read internal/provisioner/support.go — did it move? %v", err)
	}
	if !strings.Contains(string(src), `%s=<your-key>`) {
		t.Fatal("internal/provisioner/support.go no longer narrates the <your-key> " +
			"placeholder assignment — fleetKeyHandoffFormat in this file is now a " +
			"stale copy; re-anchor it.")
	}
}
