package cli

// cloud_instance_authority_cmd_test.go proves `bp cloud instance authority`
// against a mock CONTENT API (httptest.NewServer, the V3 harness shape) — never
// a live box, never the control plane.
//
// The load-bearing claims, one per criterion of task-e25b94b9db28392a:
//
//   - c1 the check is a COMMAND: it reads GET /api/workspaces + probes the export
//     route on a NAMED instance and renders both a human report and -o json;
//   - c3 NEGATIVE ARM at the CLI: a REAL 403 from the export route is never
//     treated as clean — not in the prose, not in the json, not in the exit code.
//     The CLI is the consumer of workspace_admin?/2's answer, so a client that
//     shrugged at a denial would hide exactly the breakage this row is about;
//   - c4 PER BOX: the report names the instance it read, --all is refused with
//     the reason, and the json carries an explicit fleet_verdict:null.
//
// The consumer arm (c2, internal/provisioner's ParentAdminToken) lives in
// cloud_instance_authority_consumer_test.go.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// runAuthority drives the FULL runCloud dispatcher (case "instance" → verb
// "authority") so the switch wiring is proved, not bypassed.
func runAuthority(t *testing.T, g globals, output string, args ...string) (string, string, int) {
	t.Helper()
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = output
	w.color = false
	code := runCloud(w, g, append([]string{"instance", "authority"}, args...))
	return sout.String(), serr.String(), code
}

// authorityServer is a mock main: /api/workspaces returns the membership set the
// test names, and the export route answers exportStatus. It records the bearer
// each route saw so the test can prove the operator token actually rode along.
type authorityServer struct {
	*httptest.Server
	exportHits  int
	exportPath  string
	bearerSeen  string
	exportQuery string
}

func newAuthorityServer(t *testing.T, memberships []string, exportStatus int) *authorityServer {
	t.Helper()
	as := &authorityServer{}
	as.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		as.bearerSeen = r.Header.Get("Authorization")
		switch {
		case r.URL.Path == "/api/workspaces":
			rows := make([]string, 0, len(memberships))
			for _, s := range memberships {
				rows = append(rows, fmt.Sprintf(`{"id":"ws_%s","slug":%q,"name":%q}`, s, s, s))
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"workspaces":[%s]}`, strings.Join(rows, ","))
		case strings.HasSuffix(r.URL.Path, "/export"):
			as.exportHits++
			as.exportPath = r.URL.Path
			as.exportQuery = r.URL.RawQuery
			if exportStatus >= 200 && exportStatus < 300 {
				w.Header().Set("Content-Type", "application/x-tar")
				w.WriteHeader(exportStatus)
				_, _ = w.Write([]byte("not-a-real-tar"))
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(exportStatus)
			// The real refusal shape: workspace_admin?/2 said no.
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"admin access to this workspace is required"}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"code":"not_found","message":"no route"}}`))
		}
	}))
	t.Cleanup(as.Close)
	return as
}

// TestAuthorityUncoveredTokenIsNeverClean is the NEGATIVE ARM (c3): the server
// answers a REAL 403 on export for a workspace the token holds no grant in. The
// CLI must report it, must not exit 0, and must print the GRANT remedy — never
// suggest loosening the predicate.
func TestAuthorityUncoveredTokenIsNeverClean(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default"}, http.StatusForbidden)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "table", "--workspace", "gyldendal")

	if code == exitOK {
		t.Fatalf("a 403 on export exited 0 — a denial read as clean; output:\n%s", out)
	}
	if srv.exportHits != 1 {
		t.Fatalf("want exactly one export probe, got %d", srv.exportHits)
	}
	if srv.exportPath != "/api/workspaces/gyldendal/export" {
		t.Fatalf("probe hit %q, want /api/workspaces/gyldendal/export", srv.exportPath)
	}
	if srv.bearerSeen != "Bearer operator-admin-token" {
		t.Fatalf("export probe carried %q, want the operator bearer", srv.bearerSeen)
	}
	for _, want := range []string{"UNCOVERED", "403", "NOT clean", `create_membership(<workspace_id>, <token_id>, "admin")`} {
		if !strings.Contains(out, want) {
			t.Fatalf("report is missing %q; got:\n%s", want, out)
		}
	}
	// The remedy is a GRANT. A report that even mentions relaxing the predicate
	// is the failure mode four merged PRs closed.
	for _, forbidden := range []string{"member?/2", "relax", "loosen"} {
		if strings.Contains(out, forbidden) {
			t.Fatalf("report proposes weakening the predicate (%q):\n%s", forbidden, out)
		}
	}
}

// TestAuthorityCoveredTokenIsClean is the positive endpoint the mutation returns
// to (the c5 recipe's second half): the grant exists, export authorizes, the
// check goes clean and exits 0.
func TestAuthorityCoveredTokenIsClean(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default", "gyldendal"}, http.StatusOK)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "table", "--workspace", "gyldendal")

	if code != exitOK {
		t.Fatalf("a covered token exited %d, want 0; output:\n%s", code, out)
	}
	if !strings.Contains(out, "COVERED") || !strings.Contains(out, "VERDICT    clean") {
		t.Fatalf("report did not read clean:\n%s", out)
	}
}

// TestAuthorityMembershipWithoutAdminRoleIsNotClean pins the gap a
// membership-only check would miss: the index lists the workspace (a grant
// exists) but the role is below @admin_roles, so export 403s. Coverage alone
// must not carry the verdict.
func TestAuthorityMembershipWithoutAdminRoleIsNotClean(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default", "gyldendal"}, http.StatusForbidden)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "table", "--workspace", "gyldendal")

	if code == exitOK {
		t.Fatalf("a member-but-not-admin token exited 0; output:\n%s", out)
	}
	if !strings.Contains(out, "COVERED") {
		t.Fatalf("want the membership row reported as covered:\n%s", out)
	}
	if !strings.Contains(out, "REFUSED") {
		t.Fatalf("want the export refusal reported:\n%s", out)
	}
}

// TestAuthorityJSONIsPerBoxAndNamesWhatItDidNotAnswer is c4 + the honesty half of
// c1 in the MACHINE view, which is the one a script would aggregate: the payload
// names the instance, carries fleet_verdict:null, and states that the zero-admin
// sweep was not answered here.
func TestAuthorityJSONIsPerBoxAndNamesWhatItDidNotAnswer(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default"}, http.StatusForbidden)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "json", "--workspace", "gyldendal")
	if code == exitOK {
		t.Fatalf("json path exited 0 on a 403; output:\n%s", out)
	}

	var got map[string]any
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("-o json did not emit valid JSON (%v):\n%s", err, out)
	}
	if got["scope"] != "instance" {
		t.Fatalf(`scope = %v, want "instance"`, got["scope"])
	}
	if got["instance"] != srv.URL {
		t.Fatalf("instance = %v, want %q — the report must name the box it read", got["instance"], srv.URL)
	}
	if v, present := got["fleet_verdict"]; !present || v != nil {
		t.Fatalf("fleet_verdict = %v (present=%v), want an explicit null", v, present)
	}
	if got["clean"] != false {
		t.Fatalf("clean = %v, want false on a 403", got["clean"])
	}
	sweep, _ := got["zero_admin_sweep"].(map[string]any)
	if sweep == nil || sweep["answered"] != false {
		t.Fatalf("zero_admin_sweep did not declare itself unanswered: %v", got["zero_admin_sweep"])
	}
	if s, _ := got["scope_note"].(string); !strings.Contains(s, "per instance") {
		t.Fatalf("scope_note does not say per instance: %q", s)
	}
	export, _ := got["export_probe"].(map[string]any)
	if export == nil || export["authorized"] != false || export["status"].(float64) != 403 {
		t.Fatalf("export_probe did not record the real 403: %v", got["export_probe"])
	}
}

// TestAuthorityRefusesAll is c4 ENCODED rather than warned about: there is no
// fleet mode, and the refusal says why.
func TestAuthorityRefusesAll(t *testing.T) {
	workspaceEnvIsolate(t)
	g := globals{server: "http://127.0.0.1:1", token: "t"}
	out, errOut, code := runAuthority(t, g, "table", "--all")
	if code != exitUsage {
		t.Fatalf("--all exited %d, want %d (a usage refusal); out=%s err=%s", code, exitUsage, out, errOut)
	}
	if !strings.Contains(out+errOut, "PER BOX") {
		t.Fatalf("the --all refusal does not name the reason:\n%s%s", out, errOut)
	}
}

// TestAuthorityRefusesAllThroughTheRootParser is the arm that MATTERS, and it is
// here because the sibling above did not catch a real hole. `--all` is a GLOBAL
// flag (globals.all, the pagination knob), so parseGlobals CLAIMS it and it never
// reaches the verb's argv — a guard keyed only on the verb-local bool refused
// nothing from the real entry point, and a live smoke run went ahead and checked
// a box with `--all` on the command line. This test drives parseGlobals first, so
// it fails if the guard is ever unreachable again.
func TestAuthorityRefusesAllThroughTheRootParser(t *testing.T) {
	workspaceEnvIsolate(t)

	g, rest, err := parseGlobals([]string{"cloud", "instance", "authority", "--all"})
	if err != nil {
		t.Fatalf("parseGlobals: %v", err)
	}
	// The premise, asserted rather than assumed: the ROOT parser takes --all, so
	// the verb never sees it in its own argv.
	if !g.all {
		t.Fatal("the root parser did not claim --all — this test no longer covers the hole it was written for")
	}
	for _, a := range rest {
		if a == "--all" {
			t.Fatal("--all survived into the verb argv; the local-bool guard would have been enough")
		}
	}

	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	w.output = "table"
	w.color = false
	code := runCloud(w, g, rest[1:])

	if code != exitUsage {
		t.Fatalf("--all through the root parser exited %d, want %d; out=%s err=%s", code, exitUsage, sout.String(), serr.String())
	}
	if !strings.Contains(sout.String()+serr.String(), "PER BOX") {
		t.Fatalf("the refusal does not name the reason:\n%s%s", sout.String(), serr.String())
	}
}

// TestAuthoritySQLPrintsBothQueries: the half with no HTTP door is handed over as
// runnable SQL rather than skipped. Both queries and the GRANT remedy must be
// present, and the human form must be copy-pasteable.
func TestAuthoritySQLPrintsBothQueries(t *testing.T) {
	workspaceEnvIsolate(t)
	g := globals{}
	out, _, code := runAuthority(t, g, "table", "--sql")
	if code != exitOK {
		t.Fatalf("--sql exited %d, want 0:\n%s", code, out)
	}
	for _, want := range []string{
		"FROM workspaces w",
		"LEFT JOIN workspace_memberships m",
		"admin_rows",
		"'admin' = ANY(t.permissions)",
		`create_membership(<workspace_id>, <token_id>, "admin")`,
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("--sql output is missing %q:\n%s", want, out)
		}
	}
}

// TestAuthoritySkipExportProbeDoesNotClaimAdmin: with the probe off, a present
// membership row is NOT allowed to masquerade as proven admin authority — the
// report must say the ADMIN half went unasked.
func TestAuthoritySkipExportProbeDoesNotClaimAdmin(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default", "gyldendal"}, http.StatusForbidden)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, _ := runAuthority(t, g, "table", "--workspace", "gyldendal", "--skip-export-probe")
	if srv.exportHits != 0 {
		t.Fatalf("--skip-export-probe still hit the export route %d times", srv.exportHits)
	}
	if !strings.Contains(out, "not probed") || !strings.Contains(out, "ADMIN role") {
		t.Fatalf("the skipped probe is not declared:\n%s", out)
	}
}

// TestAuthorityUnprovenStatusIsNotClean: a 500 (or any non-2xx that is not a
// clean refusal) proves nothing, and "proves nothing" must never render as
// clean. This is the arm that keeps a flaky box from minting a false all-clear.
func TestAuthorityUnprovenStatusIsNotClean(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"gyldendal"}, http.StatusInternalServerError)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "table", "--workspace", "gyldendal")
	if code == exitOK {
		t.Fatalf("a 500 export probe exited 0:\n%s", out)
	}
	if !strings.Contains(out, "UNPROVEN") {
		t.Fatalf("want the unproven state named:\n%s", out)
	}
}

// TestAuthorityDefaultTargetMirrorsTheBootstrapFold: with no --workspace and no
// context workspace, the target is "default" — the same
// `bootstrap_workspace || "default"` fold the control plane applies when it
// fills the provisioner's SupportBindSpec.
func TestAuthorityDefaultTargetMirrorsTheBootstrapFold(t *testing.T) {
	workspaceEnvIsolate(t)
	srv := newAuthorityServer(t, []string{"default"}, http.StatusOK)

	g := globals{server: srv.URL, token: "operator-admin-token"}
	out, _, code := runAuthority(t, g, "table")
	if code != exitOK {
		t.Fatalf("exited %d:\n%s", code, out)
	}
	if srv.exportPath != "/api/workspaces/default/export" {
		t.Fatalf("default target probed %q, want /api/workspaces/default/export", srv.exportPath)
	}
}
