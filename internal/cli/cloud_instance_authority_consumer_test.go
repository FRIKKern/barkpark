package cli

// cloud_instance_authority_consumer_test.go covers THE MOST-EXPOSED CONSUMER BY
// NAME (task-e25b94b9db28392a c2).
//
// internal/provisioner/support.go's exportDatasetTar authenticates with
// spec.Support.ParentAdminToken — the parent main's OWN admin token, decrypted by
// the control plane — against parent.bootstrap_workspace || "default", on exactly
// the route this check probes:
//
//	GET <parent_url>/api/workspaces/<Support.Workspace>/export?profile=dev&…
//	Authorization: Bearer <Support.ParentAdminToken>
//
// When bootstrap_workspace is NON-DEFAULT — a template-provisioned main, whose
// workspace typically arrived by IMPORT — that token may never have CREATED the
// workspace, so it holds no membership row and workspace_admin?/2 refuses. The
// two lower-risk consumers (cloud_workspace_cmd.go, cloud_support_cmd.go) both
// present resolveContext(g).Token and default to "default"; this is the one that
// bites, so this is the one exercised.
//
// The spec is constructed from the REAL provisioner types, not a local copy, so a
// rename or a re-fold of Support.Workspace breaks this test instead of leaving it
// asserting against a stale shape. The import is TEST-ONLY — the CLI binary keeps
// no dependency on internal/provisioner.

import (
	"net/http"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/provisioner"
)

// supportSpecForTemplateProvisionedMain builds the spec the control plane hands a
// support bring-up whose parent main was template-provisioned: the bootstrap
// workspace is "gyldendal" (it arrived by import), and the bearer is the parent's
// admin token.
func supportSpecForTemplateProvisionedMain(parentURL, workspace string) provisioner.SupportJobSpec {
	return provisioner.SupportJobSpec{
		Support: provisioner.SupportBindSpec{
			ParentURL:        parentURL,
			ParentAdminToken: "parent-admin-token",
			Dataset:          "production",
			Workspace:        workspace,
			Name:             "acme-demo",
		},
	}
}

// TestAuthorityFlagsTheProvisionerParentAdminTokenOnANonDefaultBootstrap is the
// c2 arm: with a NON-default bootstrap workspace, the parent admin token's
// membership set does not cover it, the export route the provisioner will call
// answers a REAL 403, and the check reports the flow as broken on that box.
func TestAuthorityFlagsTheProvisionerParentAdminTokenOnANonDefaultBootstrap(t *testing.T) {
	workspaceEnvIsolate(t)

	// The parent main: this token created only the seeded Default workspace
	// (Auth.create_token/5 binds a new token there and nowhere else), so the
	// imported "gyldendal" carries no membership row for it.
	srv := newAuthorityServer(t, []string{"default"}, http.StatusForbidden)

	spec := supportSpecForTemplateProvisionedMain(srv.URL, "gyldendal")
	target := supportBootstrapTarget(spec.Support.Workspace)
	if target != "gyldendal" {
		t.Fatalf("target = %q, want the spec's non-default bootstrap workspace", target)
	}

	g := globals{server: spec.Support.ParentURL, token: spec.Support.ParentAdminToken}
	out, _, code := runAuthority(t, g, "table", "--workspace", target)

	if code == exitOK {
		t.Fatalf("the provisioner's parent-admin flow exited clean while export 403s:\n%s", out)
	}
	// The probe must have hit the SAME route exportDatasetTar hits, with the
	// SAME bearer — otherwise this test proves something the provisioner never
	// does.
	if srv.exportPath != "/api/workspaces/gyldendal/export" {
		t.Fatalf("probed %q, want the provisioner's export route", srv.exportPath)
	}
	if srv.bearerSeen != "Bearer parent-admin-token" {
		t.Fatalf("probe carried %q, want the ParentAdminToken bearer", srv.bearerSeen)
	}
	if !strings.Contains(srv.exportQuery, "profile=dev") {
		t.Fatalf("probe query %q does not use the scrubbed profile the provisioner asks for", srv.exportQuery)
	}
	if !strings.Contains(out, "UNCOVERED") || !strings.Contains(out, "403") {
		t.Fatalf("the report does not name the uncovered token / real refusal:\n%s", out)
	}
}

// TestSupportBootstrapTargetMirrorsTheControlPlaneFold pins the fold itself
// against the provisioner's own spec type: an EMPTY bootstrap workspace resolves
// to "default" (the control plane's `parent.bootstrap_workspace || "default"`),
// a set one is honoured verbatim. If this fold ever drifts, the check would probe
// a workspace no consumer uses and report a confident verdict about the wrong
// tenant.
func TestSupportBootstrapTargetMirrorsTheControlPlaneFold(t *testing.T) {
	cases := []struct{ bootstrap, want string }{
		{"", "default"},
		{"   ", "default"},
		{"default", "default"},
		{"gyldendal", "gyldendal"},
	}
	for _, tc := range cases {
		spec := supportSpecForTemplateProvisionedMain("http://parent.example", tc.bootstrap)
		if got := supportBootstrapTarget(spec.Support.Workspace); got != tc.want {
			t.Fatalf("bootstrap %q → %q, want %q", tc.bootstrap, got, tc.want)
		}
	}
}

// TestAuthorityCoversIsExactOnSlugs: the membership predicate compares slugs the
// way the ROUTE does — literally. A case-fold here would report coverage the
// server does not honour, which is the shape of a check that says clean while the
// operator gets a 403.
func TestAuthorityCoversIsExactOnSlugs(t *testing.T) {
	set := []string{"default", "gyldendal"}
	if !authorityCovers(set, "gyldendal") {
		t.Fatal("exact slug not reported as covered")
	}
	if authorityCovers(set, "Gyldendal") {
		t.Fatal("a case-folded slug was reported as covered — the route matches literally")
	}
	if authorityCovers(nil, "default") {
		t.Fatal("an empty membership set covered something")
	}
}
