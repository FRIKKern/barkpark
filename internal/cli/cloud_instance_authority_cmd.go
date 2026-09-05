package cli

// cloud_instance_authority_cmd.go is `bp cloud instance authority` — the
// PER-BOX operator-authority check (task-e25b94b9db28392a). It turns a fact one
// worker once knew into a command anyone can run.
//
// THE FACT IT CHECKS. TenancyAuth.workspace_admin?/2
// (api/lib/barkpark/tenancy/auth.ex, @admin_roles ~w(owner admin)) consults the
// workspace_memberships GRANT only — there is NO global/platform-admin bypass.
// Auth.create_token/5 binds a newly minted token to the seeded Default workspace
// and nothing else, and a token's membership set GROWS only when it CREATES a
// workspace (Tenancy.do_create_workspace_with_owner/3 grants the creator
// "owner"). So a workspace that arrived by seeds, a migration, a bundle import,
// or another principal has NO membership row for the operator token, and that
// token's GET /api/workspaces/:slug/export and DELETE /api/workspaces/:slug are
// 403 — with a token that carries the global `admin` permission.
//
// WHAT THIS VERB CAN HONESTLY ANSWER, AND WHAT IT CANNOT. The row's two SQL
// queries do not both have an HTTP door:
//
//   - "does THIS operator token cover its target workspace?" — YES, live and
//     for real. GET /api/workspaces is membership-INNER-JOINed
//     (Tenancy.list_workspaces_for/1: "a workspace the caller has no membership
//     row in is NEVER returned"), so its body IS the token's membership set; and
//     the export probe asks the ADMIN half directly, because the index proves
//     membership but not ROLE. A 403 from export is the real refusal, not a
//     model of one.
//
//   - "which workspaces have NO administrator AT ALL (admin_rows = 0)?" — NO.
//     That is a whole-table question over workspaces LEFT JOIN
//     workspace_memberships, and every HTTP surface is membership-scoped by
//     construction, so the CLI cannot see a workspace it has no grant in. There
//     is no endpoint for it today. Rather than fake it, this verb PRINTS the
//     query (`--sql`) with its interpretation, and its report states plainly
//     that the sweep was NOT answered here. The endpoint the api lane would need
//     is named in authoritySweepEndpoint below; that is a follow-up row.
//
// PER BOX, NEVER A FLEET VERDICT (the row's whole point). The report names the
// instance it read, `-o json` carries "scope":"instance" and an explicit
// "fleet_verdict":null, and `--all` is REFUSED with the reason rather than
// quietly sampling one box and speaking for the rest. A green here says nothing
// about any other instance: "the mint path proves where a token STARTS, never
// where it ends up."
//
// THE REMEDY THIS VERB PRINTS IS ALWAYS A GRANT — TenancyAuth.create_membership(
// workspace_id, token_id, "admin") — never a loosening of workspace_admin?/2.
// Weakening the predicate toward member?/2 reinstates the cross-tenant hole four
// merged PRs closed.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
	"strings"
)

// authoritySweepEndpoint names the read the "no administrator at all" sweep
// would need to become live at the CLI. It does not exist today; the verb cites
// it so the gap has a name instead of a silent hole.
const authoritySweepEndpoint = "GET /api/admin/workspace-authority (does not exist today — the zero-admin sweep is DB-only)"

// authoritySweepSQL is the first query from the row, verbatim: every workspace
// with its administrator count. admin_rows = 0 means export and delete are
// ALREADY 403 for everyone on that workspace.
const authoritySweepSQL = `SELECT w.slug AS workspace,
       count(*) FILTER (WHERE m.role IN ('owner','admin')) AS admin_rows,
       count(m.id) AS all_rows
FROM workspaces w
LEFT JOIN workspace_memberships m ON m.workspace_id = w.id
GROUP BY w.slug
ORDER BY admin_rows;`

// authorityTokensSQL is the second query from the row: every live operator token
// and the workspaces its memberships actually cover. If the target workspace is
// missing from a token's list, that operator flow is broken ON THIS BOX.
const authorityTokensSQL = `SELECT t.id, t.label, t.permissions,
       (SELECT string_agg(w2.slug || ':' || m.role, ', ')
          FROM workspace_memberships m JOIN workspaces w2 ON w2.id = m.workspace_id
         WHERE m.principal_id = t.id) AS memberships
FROM api_tokens t
WHERE 'admin' = ANY(t.permissions) AND t.revoked_at IS NULL
ORDER BY t.label;`

// authorityScopeNote is the sentence that stops a single sample from being read
// as a fleet verdict. It rides BOTH the human report and the json payload,
// because the machine consumer is the one that would aggregate.
const authorityScopeNote = "this verdict describes THIS instance only — a pass here says NOTHING about any other box; run it per instance"

// authorityReport is one box's answer. Every field is scoped to the single
// instance named in Instance; there is deliberately no fleet-shaped container
// around it.
type authorityReport struct {
	Instance string
	Target   string
	// Workspaces is the membership set GET /api/workspaces returned — the
	// token's grants, straight from the INNER JOIN.
	Workspaces []string
	// Covered is whether Target appears in Workspaces (membership, not role).
	Covered bool
	// ExportProbed / ExportStatus record the ADMIN-half probe. The index proves
	// membership; only export proves workspace_admin?/2 said yes.
	ExportProbed bool
	ExportStatus int
}

// authorityCovers is the whole predicate this verb turns into a verdict: does
// the membership set the box reported contain the target workspace? It is the
// client-side mirror of the missing-membership condition the row's second SQL
// query looks for ("if the target workspace is missing from that token's
// memberships list, that operator flow is broken on that box").
//
// Slug comparison is exact: workspace slugs are the route path segment the
// server matches literally, so a case-fold here would report coverage the server
// does not honour.
func authorityCovers(workspaces []string, target string) bool {
	for _, w := range workspaces {
		if w == target {
			return true
		}
	}
	return false
}

// authorityExportAuthorized reports whether the export probe proved ADMIN
// authority. Only a 2xx does. A 403 is the real refusal; a 404 means no such
// workspace; anything else (401, 5xx) is UNPROVEN and must never read as clean —
// this function's default answer is false for exactly that reason.
func authorityExportAuthorized(status int) bool {
	return status >= 200 && status < 300
}

// authorityClean reports whether the box is clean FOR THIS TOKEN AND TARGET.
// Both arms must agree: the membership set must contain the target AND, when the
// export probe ran, it must have been authorized. A probe that ran and refused
// overrides a present membership row — the grant may exist with a non-admin role
// (@admin_roles is owner|admin, and Membership.roles() is wider), which is
// precisely the case a membership-only check would call clean while export 403s.
func authorityClean(r authorityReport) bool {
	if !r.Covered {
		return false
	}
	if r.ExportProbed && !authorityExportAuthorized(r.ExportStatus) {
		return false
	}
	return true
}

// supportBootstrapTarget resolves the workspace an operator flow will actually
// hit, mirroring the control plane's `parent.bootstrap_workspace || "default"`
// fold (cloud/lib/barkpark_cloud/web/router.ex) that fills
// SupportBindSpec.Workspace for internal/provisioner/support.go — the
// most-exposed consumer, which presents spec.Support.ParentAdminToken (the
// parent main's own admin token) against exactly this slug on GET
// /api/workspaces/:slug/export.
//
// It takes the slug rather than the spec so this package keeps no build-time
// dependency on internal/provisioner; the consumer test constructs the real
// provisioner.SupportJobSpec and feeds spec.Support.Workspace straight in.
func supportBootstrapTarget(bootstrapWorkspace string) string {
	if s := strings.TrimSpace(bootstrapWorkspace); s != "" {
		return s
	}
	return "default"
}

// runCloudInstanceAuthority is `bp cloud instance authority`: read one box's
// operator authority and report it. Requires a content-API token for THAT box
// (flags > env > repo file > saved config, the resolveContext ladder) — not the
// cloud session token, because the question is about the instance's own tenancy
// tables.
func runCloudInstanceAuthority(out *writer, g globals, args []string) int {
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudInstanceAuthorityHelp(out)
		return exitOK
	}
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudInstanceAuthorityHelp(out)
			return exitOK
		}
	}

	const usage = "bp cloud instance authority [--workspace <slug>] [--sql] [--skip-export-probe]"
	a, err := parseHzArgs(args, []string{"workspace"}, []string{"sql", "skip-export-probe", "all"}, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	// c4, ENCODED not warned: there is no fleet mode. Sampling one box and
	// speaking for the rest is the exact inference this row exists to prevent,
	// and the row records it would have gone wrong in BOTH directions.
	//
	// BOTH sources are read on purpose. `--all` is a GLOBAL flag (globals.all,
	// the pagination knob), so the root parser swallows it before this verb's
	// argv is built: a guard keyed only on the local bool is UNREACHABLE from
	// the real entry point and refuses nothing — measured, on a live run that
	// went ahead and checked a box while `--all` sat parsed and ignored. The
	// local bool stays because a future root-parser change could stop claiming
	// it, and a guard that survives both readings is the one worth having.
	if g.all || a.bools["all"] {
		return useError(out, "usage",
			"there is no --all: operator authority is PER BOX, so this verb reads one instance and reports one instance — "+authorityScopeNote,
			exitUsage)
	}
	if len(a.pos) > 0 {
		return useError(out, "usage",
			fmt.Sprintf("unexpected argument %q — this verb targets the instance your context points at (`bp -s <url> --token <tok> cloud instance authority`), one box per run", a.pos[0]),
			exitUsage)
	}

	// --sql is the honest half: the zero-admin sweep has no HTTP door, so the
	// verb hands the operator the query instead of pretending to have run it.
	if a.bools["sql"] {
		return emitAuthoritySQL(out)
	}

	base, token := workspaceBundleTarget(g)
	if base == "" {
		return useError(out, "usage", "no instance to check — pass `-s <url>` or set BARKPARK_SERVER", exitUsage)
	}
	if token == "" {
		return useError(out, "auth", "no token for "+base+" — pass `--token <tok>` or set BARKPARK_TOKEN", exitAuth)
	}

	target := strings.TrimSpace(a.val("workspace"))
	if target == "" {
		target = supportBootstrapTarget(strings.TrimSpace(resolveContext(g).Workspace))
	}
	if !validWorkspaceSlug(target) {
		return useError(out, "usage", fmt.Sprintf("invalid workspace slug %q", target), exitUsage)
	}

	if g.dryRun {
		out.progressf("DRY RUN — would GET %s/api/workspaces (the token's membership set)", base)
		if !a.bools["skip-export-probe"] {
			out.progressf("DRY RUN — would then GET %s/api/workspaces/%s/export (the admin-half probe, headers only)", base, target)
		}
		return exitOK
	}

	report := authorityReport{Instance: base, Target: target}

	workspaces, code, ok := fetchAuthorityMemberships(out, base, token)
	if !ok {
		return code
	}
	report.Workspaces = workspaces
	report.Covered = authorityCovers(workspaces, target)

	if !a.bools["skip-export-probe"] {
		status, perr := probeAuthorityExport(base, token, target)
		if perr != nil {
			return useError(out, "network", "export probe failed: "+perr.Error(), exitGeneric)
		}
		report.ExportProbed = true
		report.ExportStatus = status
	}

	clean := authorityClean(report)
	if emitAuthorityStructured(out, report, clean) {
		return authorityExit(clean)
	}
	renderAuthorityReport(out, report, clean)
	return authorityExit(clean)
}

// authorityExit maps the verdict onto an exit code so a scripted operator can
// gate on it: clean is 0, a reported gap is non-zero. The gap is a FINDING about
// the box, not a failure of the command, but a check that exits 0 while
// reporting a 403 is a check nobody's CI will ever notice.
func authorityExit(clean bool) int {
	if clean {
		return exitOK
	}
	return exitGeneric
}

// fetchAuthorityMemberships GETs /api/workspaces and returns the slugs. That
// route's body IS the token's membership set (the INNER JOIN in
// Tenancy.list_workspaces_for/1), which is why no separate membership read is
// needed — and why a workspace absent from it has no grant, full stop.
func fetchAuthorityMemberships(out *writer, base, token string) ([]string, int, bool) {
	req, rerr := http.NewRequest(http.MethodGet, base+"/api/workspaces", nil)
	if rerr != nil {
		return nil, useError(out, "failed", "build request: "+rerr.Error(), exitGeneric), false
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")

	resp, derr := newTransferClient().Do(req)
	if derr != nil {
		return nil, useError(out, "network", "membership read failed: "+derr.Error(), exitGeneric), false
	}
	defer resp.Body.Close()

	body, _ := readCapped(resp.Body, maxResponseBytes)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		ae := classifyError(resp.StatusCode, body)
		renderError(out, ae)
		return nil, ae.exit, false
	}

	var payload struct {
		Workspaces []struct {
			Slug string `json:"slug"`
		} `json:"workspaces"`
	}
	if jerr := json.Unmarshal(body, &payload); jerr != nil {
		return nil, useError(out, "failed", "decode /api/workspaces: "+jerr.Error(), exitGeneric), false
	}
	slugs := make([]string, 0, len(payload.Workspaces))
	for _, w := range payload.Workspaces {
		if s := strings.TrimSpace(w.Slug); s != "" {
			slugs = append(slugs, s)
		}
	}
	sort.Strings(slugs)
	return slugs, exitOK, true
}

// probeAuthorityExport asks the ADMIN half directly: GET the export route and
// return its STATUS, without downloading the bundle. The body is closed the
// moment the status line is read, so a covered token on a large workspace pays
// for headers, not gigabytes — and an uncovered one gets the real 403 the row
// demands rather than a modelled one.
//
// profile=dev is the scrubbed bundle the provisioner's own export uses; it makes
// no difference to the gate (the two-part check runs before any streaming) and
// keeps the probe the cheapest shape the route offers.
func probeAuthorityExport(base, token, target string) (int, error) {
	req, err := http.NewRequest(http.MethodGet, base+"/api/workspaces/"+target+"/export?profile=dev", nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/x-tar, application/json")
	resp, derr := newTransferClient().Do(req)
	if derr != nil {
		return 0, derr
	}
	resp.Body.Close()
	return resp.StatusCode, nil
}

// emitAuthoritySQL prints the two queries from the row with their
// interpretation. This is the ONLY honest form the zero-admin sweep can take at
// the CLI today, and saying so is the point — a verb that quietly skipped the
// half it cannot reach would report a clean box it never looked at.
func emitAuthoritySQL(out *writer) int {
	if out.emitStructured(map[string]any{
		"scope":         "instance",
		"fleet_verdict": nil,
		"scope_note":    authorityScopeNote,
		"queries": []any{
			map[string]any{
				"name":           "workspaces_with_no_administrator",
				"sql":            authoritySweepSQL,
				"interpretation": "any row with admin_rows = 0 has NO valid administrator: export and delete are ALREADY 403 for everyone on that workspace",
			},
			map[string]any{
				"name":           "admin_tokens_and_their_memberships",
				"sql":            authorityTokensSQL,
				"interpretation": "if the target workspace is missing from a token's memberships list, that operator flow is broken on THIS box",
			},
		},
		"remedy":          authorityRemedyLine,
		"endpoint_needed": authoritySweepEndpoint,
	}) {
		return exitOK
	}
	out.outf("Run these on the box, as the DB superuser. They answer PER BOX.\n")
	out.outf("\n-- 1. workspaces with no administrator\n")
	out.outf("%s\n", authoritySweepSQL)
	out.outf("\n   any row with admin_rows = 0 has NO valid administrator:\n")
	out.outf("   export and delete are ALREADY 403 for everyone on that workspace.\n")
	out.outf("\n-- 2. operator tokens and the workspaces they actually cover\n")
	out.outf("%s\n", authorityTokensSQL)
	out.outf("\n   if the target workspace is missing from a token's memberships list,\n")
	out.outf("   that operator flow is broken on THIS box.\n")
	out.outf("\nREMEDY (always a GRANT, never a predicate change):\n")
	out.outf("   %s\n", authorityRemedyLine)
	out.outf("\nSCOPE: %s\n", authorityScopeNote)
	return exitOK
}

// authorityRemedyLine is the one remedy this verb ever prints. Weakening
// workspace_admin?/2 toward member?/2 reinstates the cross-tenant hole four
// merged PRs closed; create_membership/4 validates the role against
// Membership.roles(), so an explicit "admin" is accepted.
const authorityRemedyLine = `TenancyAuth.create_membership(<workspace_id>, <token_id>, "admin")`

// emitAuthorityStructured writes the machine view. "scope":"instance" and the
// explicit "fleet_verdict":null are load-bearing: the aggregating consumer is a
// script, so the refusal to speak for the fleet must be in the JSON, not only in
// the prose.
func emitAuthorityStructured(out *writer, r authorityReport, clean bool) bool {
	export := map[string]any{"probed": r.ExportProbed}
	if r.ExportProbed {
		export["status"] = r.ExportStatus
		export["authorized"] = authorityExportAuthorized(r.ExportStatus)
	}
	return out.emitStructured(map[string]any{
		"scope":         "instance",
		"instance":      r.Instance,
		"target":        r.Target,
		"clean":         clean,
		"membership":    map[string]any{"covered": r.Covered, "workspaces": r.Workspaces},
		"export_probe":  export,
		"fleet_verdict": nil,
		"scope_note":    authorityScopeNote,
		"remedy":        authorityRemedyLine,
		"zero_admin_sweep": map[string]any{
			"answered":        false,
			"reason":          "every HTTP surface is membership-scoped, so the CLI cannot see a workspace it has no grant in; run `bp cloud instance authority --sql` and execute query 1 with psql on the box",
			"endpoint_needed": authoritySweepEndpoint,
		},
	})
}

// renderAuthorityReport writes the human view: what was read, on which box, and
// what was NOT answered here.
func renderAuthorityReport(out *writer, r authorityReport, clean bool) {
	out.outf("instance   %s\n", r.Instance)
	out.outf("target     %s\n", r.Target)

	if r.Covered {
		out.outf("membership COVERED — the token holds a grant on %q\n", r.Target)
	} else {
		out.outf("membership UNCOVERED — the token holds NO membership row for %q\n", r.Target)
	}
	if len(r.Workspaces) == 0 {
		out.outf("grants     (none — this token is a member of no workspace on this box)\n")
	} else {
		out.outf("grants     %s\n", strings.Join(r.Workspaces, ", "))
	}

	switch {
	case !r.ExportProbed:
		out.outf("export     not probed (--skip-export-probe): membership alone does not prove the ADMIN role\n")
	case authorityExportAuthorized(r.ExportStatus):
		out.outf("export     %d — GET /api/workspaces/%s/export authorized\n", r.ExportStatus, r.Target)
	case r.ExportStatus == http.StatusForbidden:
		out.outf("export     403 — GET /api/workspaces/%s/export REFUSED; this operator flow is broken on this box\n", r.Target)
	case r.ExportStatus == http.StatusNotFound:
		out.outf("export     404 — no workspace %q on this box\n", r.Target)
	default:
		out.outf("export     %d — UNPROVEN; authority was not demonstrated\n", r.ExportStatus)
	}

	out.outf("\n")
	if clean {
		out.outf("VERDICT    clean for this token and this target.\n")
	} else {
		out.outf("VERDICT    NOT clean — remedy (always a GRANT, never a predicate change):\n")
		out.outf("             %s\n", authorityRemedyLine)
	}
	out.outf("\nNOT ANSWERED HERE: which workspaces have NO administrator at all.\n")
	out.outf("  That is a whole-table read with no HTTP door (%s).\n", authoritySweepEndpoint)
	out.outf("  Run `bp cloud instance authority --sql` and execute query 1 with psql on the box.\n")
	out.outf("\nSCOPE: %s\n", authorityScopeNote)
}

func printCloudInstanceAuthorityHelp(out *writer) {
	out.outf("bp cloud instance authority — per-box operator authority check\n\n")
	out.outf("Usage:\n")
	out.outf("  bp cloud instance authority [--workspace <slug>] [--sql] [--skip-export-probe]\n\n")
	out.outf("Reads ONE instance (the one your context points at) and reports:\n")
	out.outf("  • whether the presented token's memberships cover its target workspace\n")
	out.outf("  • whether GET /api/workspaces/<target>/export is actually authorized\n\n")
	out.outf("Flags:\n")
	out.outf("  --workspace <slug>     target workspace (default: your context workspace, else \"default\" —\n")
	out.outf("                         the control plane's `bootstrap_workspace || \"default\"` fold)\n")
	out.outf("  --sql                  print the two operator queries (the zero-admin sweep is DB-only)\n")
	out.outf("  --skip-export-probe    read memberships only; do not ask the export route\n\n")
	out.outf("There is no --all. %s\n", authorityScopeNote)
}
