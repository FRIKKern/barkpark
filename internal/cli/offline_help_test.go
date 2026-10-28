package cli

import (
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// `bp org --help` must work before the server is up (run 1 F12): bp carries
// the org noun's help in its binary.
func TestOfflineHelpRendersOrgWithNoServer(t *testing.T) {
	for _, args := range [][]string{
		{"org", "--help"},
		{"org", "oidc-create", "--help"},
		{"help", "org"},
	} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			helpEnvNoManifestAtAll(t)
			resetManifestMemo()

			out, code := captureExecuteCode(t, args)
			if code != exitOK {
				t.Fatalf("exit = %d, want %d with no server; out:\n%s", code, exitOK, out)
			}
			if !strings.Contains(out, "this help comes from bp") {
				t.Fatalf("the page does not say it is bp's own copy; out:\n%s", out)
			}
			if !strings.Contains(out, "oidc-create") && !strings.Contains(out, "client_secret") {
				t.Fatalf("the org help is missing; out:\n%s", out)
			}
		})
	}
}

// The embedded file must parse, or offline help silently falls back to the
// refusal.
func TestOfflineHelpManifestParses(t *testing.T) {
	m, err := manifest.Parse(offlineHelpManifestJSON)
	if err != nil {
		t.Fatalf("offline_help_manifest.json does not parse: %v", err)
	}
	cmd, ok := m.Tree().Lookup("org", "oidc-create")
	if !ok {
		t.Fatal("offline help has no org oidc-create")
	}
	var secret *manifest.Arg
	for i := range cmd.Args {
		if cmd.Args[i].Name == "client_secret" {
			secret = &cmd.Args[i]
		}
	}
	if secret == nil || secret.Type != secretArgType {
		t.Fatalf("client_secret arg = %+v, want type %q", secret, secretArgType)
	}
	if offlineHelpManifest("task") != nil {
		t.Fatal("offline help must cover only the nouns the server put in the file")
	}
}
