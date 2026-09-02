package secretscrub

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

// fleetKeyHandoffFormat is a VERBATIM copy of the narration format string in
// internal/provisioner/support.go: the PDF-D88 key hand-off logf inside
// (*supportRun).verifyRuntime — the one line in that file carrying spec.keyVar.
// That line deliberately renders a provider key VAR NAME with a PLACEHOLDER
// value so a developer can copy the one-liner; it is the named NON-defect the
// generic scrubber must not mangle. TestHandoffNarrationStillLivesInProvisioner
// is the tripwire that catches this copy going stale.
const fleetKeyHandoffFormat = "agent provider keys are NEVER copied — hand the box its %s key yourself: ssh root@%s \"printf '%s=<your-key>\\n' >> /etc/barkpark/fleet-listener.env && systemctl restart barkpark-fleet-listener\""

// syntheticNarration carries every shape the three pre-dedup copies disagreed
// about. EVERY value here is synthetic — no real credential appears in this
// repo's tests.
const syntheticNarration = "bootstrap failed on the box; captured remote output follows\n" +
	"ANTHROPIC_API_KEY=sk-ant-synthetic0000000000\n" +
	"FLEET_LISTENER_TOKEN=synthetictoken1111111111\n" +
	"PGPASSWORD=syntheticpassword22222222\n" +
	"leftover handle bp_read_syntheticREADTOKEN333 in the log\n" +
	"DATABASE_URL=ecto://u:syntheticPASS4444@h/db\n" +
	"Authorization: Bearer syntheticbearer55555555"

var syntheticValues = []string{
	"sk-ant-synthetic0000000000",
	"synthetictoken1111111111",
	"syntheticpassword22222222",
	"bp_read_syntheticREADTOKEN333",
	"syntheticPASS4444",
	"syntheticbearer55555555",
}

// TestPatterns_GenericShapes is the "proven able to fail" arm. Run against the
// pre-dedup provisioner console redactor (a six-name allowlist plus a
// bp_admin_-only token regex) the same line leaks five of these six values;
// against the pre-dedup builder redactor it leaks the KEK shapes below.
func TestPatterns_GenericShapes(t *testing.T) {
	out := Patterns(syntheticNarration)

	for _, leaked := range syntheticValues {
		if strings.Contains(out, leaked) {
			t.Errorf("Patterns leaked %q; got:\n%s", leaked, out)
		}
	}
	// The KEY NAMES survive so a failing run is still diagnosable.
	for _, kept := range []string{
		"ANTHROPIC_API_KEY=" + Placeholder,
		"FLEET_LISTENER_TOKEN=" + Placeholder,
		"PGPASSWORD=" + Placeholder,
		"DATABASE_URL=" + Placeholder,
		"Bearer " + Placeholder,
	} {
		if !strings.Contains(out, kept) {
			t.Errorf("Patterns dropped expected marker %q; got:\n%s", kept, out)
		}
	}
}

// TestKeepsLegacySixNameCoverage guards the ONE narrowing a naive port of the
// builder's regex would cause: BARKPARK_KEK and BARKPARK_KEK_PREVIOUS contain
// neither SECRET nor KEY (K-E-K, not K-E-Y), so a shape alternation without KEK
// would silently stop redacting the key-encryption key during a rotation window.
func TestKeepsLegacySixNameCoverage(t *testing.T) {
	in := "BARKPARK_KEK=syntheticKEKvalue0000\n" +
		"BARKPARK_KEK_PREVIOUS=syntheticOldKEK1111\n" +
		"BARKPARK_CLOAK_KEY=syntheticCloak2222\n" +
		"SECRET_KEY_BASE=syntheticBase3333\n" +
		"PREVIEW_JWT_SECRET=syntheticJwt4444\n" +
		"DATABASE_URL=ecto://u:syntheticPass5555@h/db"
	out := Patterns(in)

	for _, leaked := range []string{
		"syntheticKEKvalue0000", "syntheticOldKEK1111", "syntheticCloak2222",
		"syntheticBase3333", "syntheticJwt4444", "syntheticPass5555",
	} {
		if strings.Contains(out, leaked) {
			t.Errorf("Patterns leaked legacy-allowlist value %q; got:\n%s", leaked, out)
		}
	}
	// The LONGER key must win: BARKPARK_KEK_PREVIOUS keeps its full name rather
	// than being truncated to BARKPARK_KEK with a "_PREVIOUS=..." tail.
	for _, kept := range []string{
		"BARKPARK_KEK=" + Placeholder,
		"BARKPARK_KEK_PREVIOUS=" + Placeholder,
		"BARKPARK_CLOAK_KEY=" + Placeholder,
		"SECRET_KEY_BASE=" + Placeholder,
		"PREVIEW_JWT_SECRET=" + Placeholder,
		"DATABASE_URL=" + Placeholder,
	} {
		if !strings.Contains(out, kept) {
			t.Errorf("Patterns dropped expected marker %q; got:\n%s", kept, out)
		}
	}
}

// TestPreservesPlaceholderInstruction is the named non-defect. A generic
// ALLCAPS_KEY=value scrubber would mangle the PDF-D88 hand-off one-liner into
// `ANTHROPIC_API_KEY=[REDACTED]` and destroy an instruction a developer has to
// be able to read and paste. The placeholder guard must let it through
// BYTE-FOR-BYTE.
func TestPreservesPlaceholderInstruction(t *testing.T) {
	for _, keyVar := range []string{"ANTHROPIC_API_KEY", "OPENAI_API_KEY"} {
		line := fmt.Sprintf(fleetKeyHandoffFormat, "claude", "203.0.113.9", keyVar)
		if out := Patterns(line); out != line {
			t.Errorf("the %s hand-off instruction was mangled:\n want: %s\n  got: %s", keyVar, line, out)
		}
		// And the readable part is genuinely intact, not merely equal by accident.
		if !strings.Contains(Patterns(line), keyVar+"=<your-key>") {
			t.Errorf("%s=<your-key> did not survive the scrub readable", keyVar)
		}
		// Line/2 is what every caller actually invokes — the guard must survive
		// the literal pass in front of it too.
		if out := Line(line, nil); out != line {
			t.Errorf("Line mangled the %s hand-off instruction:\n want: %s\n  got: %s", keyVar, line, out)
		}
	}
}

// TestPlaceholderGuardIsNarrow proves the guard is an exemption for an OBVIOUS
// placeholder only — it must not become a bypass. A value that merely STARTS
// with an angle-bracket group and then continues into real material is still a
// secret and is still redacted.
func TestPlaceholderGuardIsNarrow(t *testing.T) {
	in := "SECRET_KEY_BASE=<x>syntheticSmuggled6666"
	out := Patterns(in)
	if strings.Contains(out, "syntheticSmuggled6666") {
		t.Errorf("the placeholder guard became a bypass — value smuggled through:\n%s", out)
	}
}

// TestLeavesProseAlone re-asserts the scrub is a no-op on ordinary failure text
// now that the key match is shape-based rather than an explicit name list.
// Lowercase prose must never be mangled.
func TestLeavesProseAlone(t *testing.T) {
	in := "migration 20260101 failed: relation \"posts\" already exists (key=value not secret)"
	if out := Patterns(in); out != in {
		t.Errorf("Patterns mangled clean output:\n in: %s\nout: %s", in, out)
	}
}

// TestLiterals covers the KNOWN-VALUE half, including the empty-string entry
// that would otherwise turn every character boundary into a [REDACTED].
func TestLiterals(t *testing.T) {
	got := Literals("body carried LITERALSECRET inline", []string{"", "LITERALSECRET"})
	if strings.Contains(got, "LITERALSECRET") {
		t.Errorf("registered literal secret not redacted: %q", got)
	}
	if got != "body carried "+Placeholder+" inline" {
		t.Errorf("empty secret corrupted the line: %q", got)
	}
}

// TestLine_LiteralsRunBeforePatterns proves the composition order: a registered
// literal is redacted whatever shape it has, including one no pattern matches.
func TestLine_LiteralsRunBeforePatterns(t *testing.T) {
	got := Line("deploy used deploykey-literal-xyz and PGPASSWORD=syntheticpassword22222222", []string{"deploykey-literal-xyz"})
	for _, leaked := range []string{"deploykey-literal-xyz", "syntheticpassword22222222"} {
		if strings.Contains(got, leaked) {
			t.Errorf("Line leaked %q; got: %s", leaked, got)
		}
	}
}

// TestHandoffNarrationStillLivesInProvisioner is the anti-drift tripwire for
// fleetKeyHandoffFormat above: this package must not import internal/provisioner
// (provisioner imports this), so the format string is a COPY. If the real
// narration is reworded or moved, this fails loudly rather than letting the
// placeholder-guard test silently guard a string nothing emits.
func TestHandoffNarrationStillLivesInProvisioner(t *testing.T) {
	src, err := os.ReadFile("../provisioner/support.go")
	if err != nil {
		t.Fatalf("cannot read internal/provisioner/support.go — did it move? %v", err)
	}
	if !strings.Contains(string(src), `%s=<your-key>`) {
		t.Fatal("internal/provisioner/support.go no longer narrates the <your-key> " +
			"placeholder assignment — fleetKeyHandoffFormat in this file is now a " +
			"stale copy; re-anchor it.")
	}
}
