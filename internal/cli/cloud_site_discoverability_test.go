package cli

// The stranger's first run (ssw8-bl-stranger-first-run-rehearsal) found gaps a
// reader of `-h` can never cross. These pin the three that are pure CLI:
//
//  1. `delete` is DISPATCHED (runCloudSite's "delete","rm" arm) but absent from
//     the -h USAGE block, so the undo verb is unreachable by anyone who does not
//     read Go.
//  2. --template and --theme are accepted by create's parser and named in its
//     usage CONSTANT, but never appear in the -h USAGE line — so a reader of -h
//     never learns the flagship starter exists.
//  3. --kind does not follow --framework. The console derives it
//     (cloud/priv/static/app.js siteKindFor: astro -> static, everything else ->
//     node), so `--framework nextjs` alone builds a kind=static request from the
//     CLI and a kind=node one from the dashboard. The server rejects the CLI's
//     honestly, but the console cannot even EXPRESS the mistake.

import (
	"encoding/json"
	"strings"
	"testing"
)

// siteHelpText renders `bp cloud site -h` the way a stranger reads it.
func siteHelpText(t *testing.T) string {
	t.Helper()
	stdout, _, code := runSite(t, "table", "-h")
	if code != exitOK {
		t.Fatalf("`cloud site -h` exit = %d, want 0", code)
	}
	return stdout
}

// siteHelpUsage is the USAGE block only — the verb list a stranger scans. It
// ends at the first section break after USAGE, so a verb mentioned only in prose
// ("rollback and delete exit-code the control plane's typed refusal") does NOT
// count as documented.
func siteHelpUsage(t *testing.T, help string) string {
	t.Helper()
	i := strings.Index(help, "USAGE")
	if i < 0 {
		t.Fatalf("`cloud site -h` has no USAGE block:\n%s", help)
	}
	rest := help[i:]
	if j := strings.Index(rest, "\nWHAT IT DOES"); j >= 0 {
		return rest[:j]
	}
	return rest
}

// Every verb the dispatcher accepts must be reachable from the USAGE block. The
// stranger's finding was `delete`: dispatched, undocumented, and the ONLY undo.
func TestCloudSiteHelpDocumentsEveryDispatchedVerb(t *testing.T) {
	usage := siteHelpUsage(t, siteHelpText(t))
	for _, verb := range []string{"ls", "create", "deploy", "rollback", "delete", "status", "open", "preflight", "settings"} {
		if !strings.Contains(usage, "bp cloud site "+verb) {
			t.Errorf("`bp cloud site %s` is dispatched but absent from the -h USAGE block — a stranger cannot discover it:\n%s", verb, usage)
		}
	}
}

// Every flag create's parser accepts must be visible in the USAGE block. The
// stranger's finding was --template/--theme: parsed, named in the usage
// CONSTANT, invisible in -h, so the flagship starter is undiscoverable.
func TestCloudSiteHelpDocumentsCreateFlags(t *testing.T) {
	usage := siteHelpUsage(t, siteHelpText(t))
	for _, flag := range []string{"--name", "--dataset", "--instance", "--framework", "--kind", "--doc-type", "--template", "--theme", "--deploy"} {
		if !strings.Contains(usage, flag) {
			t.Errorf("create accepts %s but the -h USAGE block never names it:\n%s", flag, usage)
		}
	}
}

// --kind FOLLOWS --framework when it is not given, mirroring the console's
// siteKindFor. Passing --framework nextjs alone must not silently build a
// static-kind request the server then rejects.
func TestCloudSiteCreateKindFollowsFramework(t *testing.T) {
	cases := []struct {
		framework string
		wantKind  string
	}{
		{"nextjs", "node"},
		{"astro", "static"},
		{"", "static"}, // framework defaults to astro
	}
	for _, tc := range cases {
		t.Run("framework="+tc.framework, func(t *testing.T) {
			cp := newSiteCP(t)
			cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"` + tc.wantKind + `","framework":"astro","workspace":"acme","project":"app","dataset":"production"}}`}
			cp.serve()

			args := []string{"create", "--name", "app", "--dataset", "acme/app/production", "--instance", testInstanceID}
			if tc.framework != "" {
				args = append(args, "--framework", tc.framework)
			}
			stdout, stderr, code := runSite(t, "table", args...)
			if code != exitOK {
				t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
			}
			var got struct{ Kind string }
			if err := json.Unmarshal(cp.createBody, &got); err != nil {
				t.Fatalf("decode create body: %v (raw %s)", err, cp.createBody)
			}
			if got.Kind != tc.wantKind {
				t.Errorf("--framework %q with no --kind sent kind=%q, want %q (the console's siteKindFor derives it; the CLI must not diverge)", tc.framework, got.Kind, tc.wantKind)
			}
		})
	}
}

// An EXPLICIT --kind still wins over the derivation — the flag is not advisory.
func TestCloudSiteCreateExplicitKindWinsOverFramework(t *testing.T) {
	cp := newSiteCP(t)
	cp.createResp = fakeResp{200, `{"site":{"id":"` + testSiteID + `","name":"app","slug":"app","kind":"static","framework":"nextjs","workspace":"acme","project":"app","dataset":"production"}}`}
	cp.serve()

	stdout, stderr, code := runSite(t, "table", "create", "--name", "app", "--dataset", "acme/app/production", "--instance", testInstanceID, "--framework", "nextjs", "--kind", "static")
	if code != exitOK {
		t.Fatalf("exit=%d want 0\nstdout:%s\nstderr:%s", code, stdout, stderr)
	}
	var got struct{ Kind string }
	if err := json.Unmarshal(cp.createBody, &got); err != nil {
		t.Fatalf("decode create body: %v (raw %s)", err, cp.createBody)
	}
	if got.Kind != "static" {
		t.Errorf("explicit --kind static was overridden to %q — the flag must win", got.Kind)
	}
}
