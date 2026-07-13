package cli

// cloud_workspace_cmd.go is `bp cloud workspace export|import` — the operator's
// terminal handle on the per-workspace bundle route (Perfect-Plan BUILD Slice
// B2, charter D22/D23). It is the Go twin of the shipped Elixir bundle engine
// (Barkpark.Tenancy.WorkspaceBundle) exposed over the B1 admin HTTP route:
//
//	bp cloud workspace export <slug> [--file <out>]     GET  /api/workspaces/:slug/export
//	bp cloud workspace import <slug>  --file <tar> --yes POST /api/workspaces/:slug/import
//
// Transport is plain HTTP to the CONTENT API — the configured `bp` server + its
// admin bearer (resolveContext, the same layer every content verb resolves) —
// NOT the SSH `instSSHStream` seam the hetzner instance transfer uses, and NOT
// the whole-instance `bp-bundle-v1` object-storage format (internal/cli/cloud/
// bundle.go). The two never collide: this verb lands in the hand-rolled runCloud
// switch with its own route and its own single-workspace tar shape.
//
// export STREAMS the tar body straight to a file (a workspace bundle can be
// large — the client caps only the connection phase, never the body, exactly
// like the media-transfer client). import is a DESTRUCTIVE consumer: it RESTORES
// a bundle into a workspace scope that the engine assumes is CLEAN — the
// string-keyed members are ON CONFLICT idempotent but the copy-strategy members
// (root/E1/E2) collide if the target still holds content — so it is gated behind
// --yes and honours the global --dry-run as a preview default (print the request
// it WOULD send, send nothing). Both surface honest states — a missing file, a
// refused write, a server error map onto the CLI's stable exit-code scheme
// through the shared error seam, never a silent success.

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

// runCloudWorkspace routes `bp cloud workspace <verb> …` to export/import. It is
// wired from the runCloud switch (case "workspace"), a sibling of the instance
// verbs — no manifest command (D22: the route is bare, off the manifest, so it
// trips zero OpenAPI drift gate).
func runCloudWorkspace(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudWorkspaceHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		if g.help {
			printCloudWorkspaceHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing workspace command (run `bp cloud workspace -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "export":
		return runCloudWorkspaceExport(out, g, args[1:])
	case "import":
		return runCloudWorkspaceImport(out, g, args[1:])
	case "help":
		printCloudWorkspaceHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown workspace command %q (run `bp cloud workspace -h` for usage)", args[0]), exitUsage)
	}
}

// workspaceBundleTarget resolves the content-API base URL + admin bearer for the
// bundle route from the standard content context (flags > env > saved server >
// baked localhost). The bundle route is admin-gated SERVER-SIDE, so a
// non-admin/expired bearer round-trips to a 401/403 that maps onto exitAuth
// through the shared error seam — this resolves the transport, it does not
// second-guess the server's authority (the resolved token always carries the
// baked dev-token floor, so a client-side "empty token" check is unreachable).
func workspaceBundleTarget(g globals) (base, token string) {
	ctx := resolveContext(g)
	base = strings.TrimRight(strings.TrimSpace(ctx.Server), "/")
	token = strings.TrimSpace(ctx.Token)
	return base, token
}

// validWorkspaceSlug fences the slug that rides in the route path: non-empty and
// free of a path separator / whitespace, so it can never traverse out of the
// /api/workspaces/:slug/ segment. Server-side validation is the authority; this
// is a cheap client guard against an obvious typo becoming a wrong request.
func validWorkspaceSlug(slug string) bool {
	if strings.TrimSpace(slug) == "" {
		return false
	}
	return !strings.ContainsAny(slug, "/ \t\n?#")
}

// runCloudWorkspaceExport is `bp cloud workspace export <slug> [--file <out>]`:
// GET the workspace's bundle and stream the tar to a file (default <slug>.tar, or
// `-` for stdout). Read-only — a --dry-run prints the request it would make and
// sends nothing.
func runCloudWorkspaceExport(out *writer, g globals, args []string) int {
	const usage = "bp cloud workspace export <slug> [--file <out>]"
	a, err := parseHzArgs(args, []string{"file"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <slug> (usage: %s)", usage), exitUsage)
	}
	slug := a.pos[0]
	if !validWorkspaceSlug(slug) {
		return useError(out, "usage", fmt.Sprintf("invalid workspace slug %q", slug), exitUsage)
	}
	outPath := strings.TrimSpace(a.val("file"))
	if outPath == "" {
		outPath = slug + ".tar"
	}

	base, token := workspaceBundleTarget(g)
	url := base + "/api/workspaces/" + slug + "/export"

	if g.dryRun {
		out.progressf("DRY RUN — would GET %s → %s", url, exportDest(outPath))
		return exitOK
	}

	req, rerr := http.NewRequest(http.MethodGet, url, nil)
	if rerr != nil {
		return useError(out, "failed", "build request: "+rerr.Error(), exitGeneric)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/x-tar")

	resp, derr := newTransferClient().Do(req)
	if derr != nil {
		return useError(out, "network", "export request failed: "+derr.Error(), exitGeneric)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := readCapped(resp.Body, maxResponseBytes)
		ae := classifyError(resp.StatusCode, body)
		renderError(out, ae)
		return ae.exit
	}

	// Success: stream the tar body to the destination. `-` writes to stdout (no
	// receipt line — the raw bytes ARE the output for a pipe); a path writes the
	// file and prints a receipt naming the byte count.
	if outPath == "-" {
		if _, cerr := io.Copy(out.stdout, resp.Body); cerr != nil {
			return useError(out, "failed", "stream export to stdout: "+cerr.Error(), exitGeneric)
		}
		return exitOK
	}

	f, ferr := os.Create(outPath)
	if ferr != nil {
		return useError(out, "failed", "create output file: "+ferr.Error(), exitGeneric)
	}
	n, cerr := io.Copy(f, resp.Body)
	if closeErr := f.Close(); closeErr != nil && cerr == nil {
		cerr = closeErr
	}
	if cerr != nil {
		return useError(out, "failed", "write export file: "+cerr.Error(), exitGeneric)
	}

	if payload := map[string]any{"workspace": slug, "file": outPath, "bytes": n}; out.emitStructured(payload) {
		return exitOK
	}
	out.outf("Exported workspace %s → %s (%s)", slug, outPath, humanBytes(float64(n)))
	return exitOK
}

// exportDest renders the export destination for the dry-run line: `-` reads as
// stdout, a path stays literal.
func exportDest(path string) string {
	if path == "-" {
		return "stdout"
	}
	return path
}

// runCloudWorkspaceImport is `bp cloud workspace import <slug> --file <tar>`:
// POST the tar body to the import route, which RESTORES the bundle into the
// workspace scope (the engine assumes a CLEAN target — E3/allowlist members are
// ON CONFLICT idempotent, but the copy-strategy members collide against existing
// content). Destructive, so it is gated: --dry-run (or the global --dry-run)
// previews the request and sends nothing; without --yes it refuses; with --yes
// it posts the bytes and prints the {tables,total_rows} receipt.
func runCloudWorkspaceImport(out *writer, g globals, args []string) int {
	const usage = "bp cloud workspace import <slug> --file <tar> --yes"
	a, err := parseHzArgs(args, []string{"file"}, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) != 1 {
		return useError(out, "usage", fmt.Sprintf("want exactly one <slug> (usage: %s)", usage), exitUsage)
	}
	slug := a.pos[0]
	if !validWorkspaceSlug(slug) {
		return useError(out, "usage", fmt.Sprintf("invalid workspace slug %q", slug), exitUsage)
	}
	file := strings.TrimSpace(a.val("file"))
	if file == "" {
		return useError(out, "usage", fmt.Sprintf("missing --file <tar> (usage: %s)", usage), exitUsage)
	}

	base, token := workspaceBundleTarget(g)
	url := base + "/api/workspaces/" + slug + "/import"

	// Preview default: --dry-run (or the global --dry-run) prints the request and
	// sends nothing. This is checked BEFORE the --yes gate so an operator can
	// always preview a destructive import without first arming it.
	if g.dryRun {
		out.progressf("DRY RUN — would POST %s (%s) → %s", file, url, "RESTORE into workspace "+slug)
		return exitOK
	}

	// Destructive gate: import WRITES bundle content into the workspace, so it
	// refuses without an explicit --yes (the same write-guard the prod-mutating
	// verbs use).
	if !g.yes {
		return useError(out, "usage",
			fmt.Sprintf("refusing to import into workspace %q without --yes — this writes bundle content into it (a restore into a clean scope); pass --yes to proceed or --dry-run to preview", slug),
			exitUsage)
	}

	f, ferr := os.Open(file)
	if ferr != nil {
		return useError(out, "failed", "open import file: "+ferr.Error(), exitGeneric)
	}
	defer f.Close()
	fi, sterr := f.Stat()
	if sterr != nil {
		return useError(out, "failed", "stat import file: "+sterr.Error(), exitGeneric)
	}

	req, rerr := http.NewRequest(http.MethodPost, url, f)
	if rerr != nil {
		return useError(out, "failed", "build request: "+rerr.Error(), exitGeneric)
	}
	req.ContentLength = fi.Size()
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/x-tar")

	resp, derr := newTransferClient().Do(req)
	if derr != nil {
		return useError(out, "network", "import request failed: "+derr.Error(), exitGeneric)
	}
	defer resp.Body.Close()
	body, brerr := readCapped(resp.Body, maxResponseBytes)
	if brerr != nil {
		return useError(out, "failed", "read import response: "+brerr.Error(), exitGeneric)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		ae := classifyError(resp.StatusCode, body)
		renderError(out, ae)
		return ae.exit
	}

	// Machine consumers get the response bytes verbatim (the receipt IS the
	// contract). The human view names the workspace and the {tables,total_rows}
	// the engine reported.
	if out.output == "json" || out.output == "yaml" {
		out.renderRaw(body)
		return exitOK
	}
	tables, rows := importCounts(body)
	out.outf("Imported workspace %s — %s across %s", slug, pluralize(rows, "row"), pluralize(tables, "table"))
	return exitOK
}

// importCounts pulls the {tables,total_rows} pair from the import receipt. A
// receipt that is not the expected shape (an older/newer server) yields -1 for
// the missing field so the caller can still print an honest line rather than a
// fake zero.
func importCounts(body []byte) (tables, rows int) {
	var r struct {
		Tables    *int `json:"tables"`
		TotalRows *int `json:"total_rows"`
	}
	tables, rows = -1, -1
	if err := json.Unmarshal(body, &r); err == nil {
		if r.Tables != nil {
			tables = *r.Tables
		}
		if r.TotalRows != nil {
			rows = *r.TotalRows
		}
	}
	return tables, rows
}

// pluralize renders "<n> <noun>[s]" with an honest em dash when the count is
// unknown (-1 — a receipt that omitted the field), never a fabricated zero.
func pluralize(n int, noun string) string {
	if n < 0 {
		return "— " + noun + "s"
	}
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// printCloudWorkspaceHelp writes `bp cloud workspace` usage.
func printCloudWorkspaceHelp(out *writer) {
	const help = `bp cloud workspace — export/import a single workspace as a portable bundle.

USAGE
  bp cloud workspace export <slug> [--file <out>]        download the bundle tar
  bp cloud workspace import <slug>  --file <tar> --yes    restore the bundle (DESTRUCTIVE)

EXPORT
  GETs /api/workspaces/<slug>/export and streams the tar to <out> (default
  <slug>.tar, or ` + "`-`" + ` for stdout). Read-only. The bundle is a bp-export-v1 tar
  (manifest.json + per-table COPY dumps) scoped to the one workspace — the Go
  twin of the shipped Barkpark.Tenancy.WorkspaceBundle engine.

IMPORT
  POSTs the tar body to /api/workspaces/<slug>/import, which RESTORES the bundle
  into the workspace scope. The engine assumes a CLEAN target — E3/allowlist
  members are ON CONFLICT idempotent, but the copy-strategy members collide
  against existing content, so restore into an empty scope. Because it writes it
  is gated:
    --dry-run   preview the request, send nothing (also honoured via the global --dry-run)
    --yes       required to actually apply — without it the command refuses
  On success it prints the {tables,total_rows} the engine reported.

TRANSPORT
  Plain HTTP to the CONTENT API — the configured server (` + "`-s`" + `/BARKPARK_API_URL)
  and its admin bearer (` + "`--token`" + `/BARKPARK_API_TOKEN). The route is admin-only,
  so an absent token is refused up front. This is NOT the SSH instance-transfer
  seam and NOT the whole-instance bp-bundle-v1 archive.`
	out.outf("%s", help)
}
