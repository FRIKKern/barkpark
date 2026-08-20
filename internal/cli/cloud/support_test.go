package cloud

import (
	"strings"
	"testing"
)

// TestSupportResetDefaultWorkspaceStep_DeleteTolerantScript pins the reset
// builder both chains gate on ws=="default" (the warm-image bake carries the
// seed lineage's ~27 docs forward, so the box's own default workspace fails
// the merge engine's fail-closed empty-shell proof and the import 409s
// workspace_slug_conflict): the script must run the admin plane the proven
// way (mix run under the app's release env, asdf sourced), delete via
// Tenancy.delete_workspace, TOLERATE an already-absent workspace (re-runs
// converge), fail loud otherwise, and scrub the .env secrets it sources.
func TestSupportResetDefaultWorkspaceStep_DeleteTolerantScript(t *testing.T) {
	s := SupportResetDefaultWorkspaceStep()

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("reset step must be a bash -lc script, got %v", s.Argv)
	}
	script := s.Argv[2]

	for _, want := range []string{
		// adminTokenStep's proven on-box admin-plane mechanics, verbatim.
		". /opt/barkpark/.env",
		". /root/.asdf/asdf.sh",
		"cd /opt/barkpark/api && mix run -e",
		// The delete itself, slug-resolved…
		`Barkpark.Tenancy.get_workspace_by_slug("default")`,
		"Barkpark.Tenancy.delete_workspace(ws)",
		// …REPORTING the measured doc count on the output path BEFORE deleting
		// (the seed size was unmeasured "~27 docs" folklore; this narrated
		// count is the only observation of the image seed that survives the
		// reset — PDF-D103's honest-reporting half)…
		"require Ecto.Query",
		`doc_count = Barkpark.Repo.aggregate(Ecto.Query.where(Barkpark.Content.Document, workspace_id: ^ws.id), :count)`,
		`IO.puts("default workspace carries #{doc_count} document(s) - deleting them with the workspace")`,
		`IO.puts("default workspace deleted - #{doc_count} document(s) destroyed (measured, not folklore)")`,
		// …tolerating absent (nil → narrated no-op, exit 0)…
		`nil -> IO.puts("default workspace already absent`,
		// …and failing LOUD on a delete error (never a half-reset import target).
		"System.halt(1)",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("reset script must contain %q\nscript:\n%s", want, script)
		}
	}

	// The step is DB-direct — no bearer token anywhere in it — but it sources
	// .env, so the env-secret pattern scrub must be on.
	if !s.RedactEnvSecrets {
		t.Fatal("the reset step sources /opt/barkpark/.env — RedactEnvSecrets must be set")
	}
	if strings.Contains(script, "BP_TOK") {
		t.Fatalf("the reset step must not carry a token (mix run is DB-direct)\nscript:\n%s", script)
	}
}

// TestSupportAdminTokenStep_DelegatesToGoLiveMint pins that the exported
// re-mint wrapper IS the go-live adminTokenStep (revoke → ensure_default_scope
// → mint, converging on re-run) with its custody posture intact — the token in
// Argv only, listed in Redact, never in the narrated Title/Cmd. Both chains
// run it twice on the ws=="default" path because BOTH default-workspace
// deletes (the reset step's and the import's PDS-D9 adopt-delete) cascade the
// box admin token (api_tokens.workspace_id :delete_all).
func TestSupportAdminTokenStep_DelegatesToGoLiveMint(t *testing.T) {
	const tok = "bp_admin_remintme456"
	s := SupportAdminTokenStep(tok)

	if len(s.Argv) != 3 || s.Argv[0] != "bash" || s.Argv[1] != "-lc" {
		t.Fatalf("admin-token step must be a bash -lc script, got %v", s.Argv)
	}
	script := s.Argv[2]
	for _, want := range []string{
		"Barkpark.Seeds.Shared.ensure_default_scope()",
		"Barkpark.Auth.revoke_token",
		"Barkpark.Auth.create_token",
		"export BP_TOK='" + tok + "'",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("admin-token script must contain %q\nscript:\n%s", want, script)
		}
	}
	if strings.Contains(s.Title, tok) || strings.Contains(s.Cmd, tok) {
		t.Fatal("the admin token must never appear in the narrated Title/Cmd")
	}
	redacted := false
	for _, r := range s.Redact {
		if r == tok {
			redacted = true
		}
	}
	if !redacted {
		t.Fatal("the admin-token step must Redact the token")
	}
	if !s.RedactEnvSecrets {
		t.Fatal("the admin-token step sources /opt/barkpark/.env — RedactEnvSecrets must be set")
	}
}

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
