package cli

import (
	"os"
	"path/filepath"
	"testing"
)

// repofile_credential_binding_test.go — THE BINDING through the repo file.
//
// A .barkpark.json that names a server with NO saved entry overlays only the
// server; the active token underneath it is still the one saved for the config's
// own active server. The binding compared the credential to the OVERLAID server,
// so the two always matched and the saved credential rode along to whatever host
// the repo file named. A repo file arrives with any clone, so this let a checked
// out repository choose where your saved token goes.
//
// Measured on the stranger walk, 2026-10-01: `bp setup --target local` saved a
// local admin token, and `bp whoami` from inside this repository (whose
// .barkpark.json pins https://guerrilla.barkpark.cloud) reported
// token_source "saved" with that local token's tail, sent to guerrilla.

// inRepoPinnedTo chdirs into a fresh directory holding a .barkpark.json that
// names server.
func inRepoPinnedTo(t *testing.T, server string) {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".barkpark.json"), []byte(`{"server":"`+server+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
}

func TestRepoFileServerDoesNotInheritAnotherServersSavedCredential(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	savedFor(t, pairingHostA, pairingSavedToken)
	inRepoPinnedTo(t, "http://repo-pinned.example")

	ctx, prov := resolveContextProv(globals{})
	if ctx.Server != "http://repo-pinned.example" {
		t.Fatalf("server = %q, want the repo file's server", ctx.Server)
	}
	if ctx.Token == pairingSavedToken {
		t.Fatalf("BINDING BYPASSED — the credential saved for %s followed .barkpark.json to %s",
			pairingHostA, ctx.Server)
	}
	if ctx.Token != bakedDefaults().Token {
		t.Fatalf("withheld token fell to %q, want the baked floor %q", ctx.Token, bakedDefaults().Token)
	}
	if prov.WithheldFrom != pairingHostA {
		t.Fatalf("prov.WithheldFrom = %q, want %q so the notice names the credential's home", prov.WithheldFrom, pairingHostA)
	}
}

// Control: a repo file that names the saved server itself (by URL) still sends
// its credential. Without this arm "never send a token under a repo file" would
// pass the test above.
func TestRepoFileNamingTheSavedServerStillSendsItsCredential(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	savedFor(t, pairingHostA, pairingSavedToken)
	inRepoPinnedTo(t, pairingHostA)

	ctx, prov := resolveContextProv(globals{})
	if ctx.Token != pairingSavedToken || prov.credentialWithheld() {
		t.Fatalf("token=%q withheld_from=%q: a repo file pinned to the saved server must keep its credential",
			ctx.Token, prov.WithheldFrom)
	}
}

// Wire arm: through Execute, against a header-recording server that the repo
// file names, the saved credential appears in no request.
func TestRepoFilePinnedHostReceivesNoForeignSavedCredential(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	srv := newAuthRecorder()
	defer srv.Close()
	savedFor(t, pairingHostA, pairingSavedToken)
	inRepoPinnedTo(t, srv.URL)

	_, stderr, _ := captureExecuteArgv(t, "doc", "ls", "quiz")
	if len(srv.seen()) == 0 {
		t.Fatalf("VACUOUS: the recorder received no request.\nstderr:\n%s", stderr)
	}
	if srv.sawCredential(pairingSavedToken) {
		t.Fatalf("the credential saved for %s reached the repo-pinned host %s; headers=%q", pairingHostA, srv.URL, srv.seen())
	}
}
