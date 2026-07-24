package cloud

import (
	"strings"
	"testing"
)

// TestSupportMergeImportStep_CarriesItsEvidence pins the instrumentation
// contract for task-63a199c0a0ce2a06: the live on-box merge-import 500 surfaced
// as a bare "exit status 8" because bp's error body and the box-side barkpark
// crash log never left the box. The shared step (both support chains build it)
// must echo bp's combined output UNCONDITIONALLY, dump the barkpark journal
// tail on failure, and preserve bp's exit status — while keeping the custody
// posture (box admin token in Argv only, listed in Redact).
func TestSupportMergeImportStep_CarriesItsEvidence(t *testing.T) {
	const ws = "tpl-instance-260724"
	const tok = "bp_admin_boxtoken123"
	s := SupportMergeImportStep(ws, tok)

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("import step must be a bash -lc script, got %v", s.Argv)
	}
	script := s.Argv[2]

	for _, want := range []string{
		// The import command itself, targeting the claim's workspace.
		"cloud workspace import '" + ws + "' --file /opt/barkpark-fleet/dataset.tar --yes --merge",
		// bp's combined output is captured and ALWAYS echoed.
		`out=$(bp -s http://localhost:4000 --token "$BP_TOK" cloud workspace import`,
		`printf '%s\n' "$out"`,
		// On failure the box-side crash evidence follows…
		"bp import exited $rc",
		"journalctl -u barkpark -n 120 --no-pager",
		// …and bp's exit status is preserved (exit 8 stays exit 8).
		"exit $rc",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("import script must contain %q\nscript:\n%s", want, script)
		}
	}

	// set -e must not eat the captured non-zero exit before the evidence dump:
	// the bp invocation rides an `|| rc=$?` guard.
	if !strings.Contains(script, "|| rc=$?") {
		t.Fatalf("the bp invocation must guard its exit status with `|| rc=$?` under set -e\nscript:\n%s", script)
	}

	// Custody: the token rides Argv only and is redacted; Title/Cmd never carry it.
	if strings.Contains(s.Title, tok) || strings.Contains(s.Cmd, tok) {
		t.Fatal("the box admin token must never appear in the narrated Title/Cmd")
	}
	redacted := false
	for _, r := range s.Redact {
		if r == tok {
			redacted = true
		}
	}
	if !redacted {
		t.Fatal("the import step must Redact the box admin token")
	}
}
