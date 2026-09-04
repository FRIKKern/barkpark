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

// PULL DIALECT (PDS wave 1). On top of the B2 bundle verbs the pair also speaks
// the personal-development-server pull:
//
//	export --profile full|dev --dataset <slug>   ->  ?profile=&dataset= (scrub AT export)
//	export --source-server <url>                 ->  ?source_server= (provenance passthrough)
//	import --merge                               ->  ?mode=merge (fail-closed server-side)
//	both   --with-blobs [--blobs <dir>]          ->  the media sidecar channel
//
// --dataset needs one seam the other flags do not: it collides with the GLOBAL
// -d/--dataset, which parseGlobals eats wherever it appears, so the grain is
// resolved by exportDatasetScope from the global capture — but only when the
// flag was EXPLICITLY typed (g.datasetSet), never from the ambient saved
// context. See that function for why both halves matter (PDS-D62).
//
// The bundle carries NO blob bytes — it is a DB-only tar — so media travels on a
// second, explicitly-requested channel: export parses the tar's
// `tables/media_files.copy` member for the server-generated relative paths and
// GETs each one from `<source>/media/files/<path>` into `<bundle>.blobs/`;
// import PUTs each sidecar file back path-verbatim to
// `<target>/api/workspaces/<slug>/media/blob/<path>`. Every blob moves ONE AT A
// TIME through io.Copy — a full bundle's media set is far too large to hold in
// RAM — and the report is honest: fetched/uploaded/failed counts, every failure
// NAMED, and a non-zero exit whenever any blob failed while --with-blobs was
// asked for (a silent partial media set is the exact lie this channel exists to
// prevent).
//
// The cloud-target line before an import is UX only — defense in depth, never
// the enforcement. `bp migrate`'s --yes warning is likewise advisory; the real
// refusal is server-side (403 `bundle_import_disabled` unless the operator opted
// into `:allow_bundle_import`), and that is where it belongs.

import (
	"archive/tar"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
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
	const usage = "bp cloud workspace export <slug> [--file <out>] [--profile full|dev] [--dataset <slug>] [--source-server <url>] [--with-blobs [--blobs <dir>]]"
	a, err := parseHzArgs(args, []string{"file", "profile", "dataset", "source-server", "blobs"}, []string{"with-blobs"}, usage)
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
	withBlobs := a.bools["with-blobs"]
	// The blob sidecar re-READS the saved tar to learn its media paths, so it
	// cannot ride a stdout pipe — refuse the combination up front rather than
	// half-doing it.
	if withBlobs && outPath == "-" {
		return useError(out, "usage", "--with-blobs needs a --file on disk (the sidecar re-reads the bundle to find its media paths); drop --with-blobs to stream to stdout", exitUsage)
	}
	blobDir := strings.TrimSpace(a.val("blobs"))
	if blobDir == "" {
		blobDir = outPath + ".blobs"
	}

	base, token := workspaceBundleTarget(g)
	url := base + "/api/workspaces/" + slug + "/export" +
		bundleScopeQuery(a.val("profile"), exportDatasetScope(g, a), a.val("source-server"))

	if g.dryRun {
		out.progressf("DRY RUN — would GET %s → %s", url, exportDest(outPath))
		if withBlobs {
			out.progressf("DRY RUN — would then fetch each media_files blob → %s", blobDir)
		}
		return exitOK
	}

	req, rerr := http.NewRequest(http.MethodGet, url, nil)
	if rerr != nil {
		return useError(out, "failed", "build request: "+rerr.Error(), exitGeneric)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	// `application/x-tar` is the bundle body type, but the route rides the `:api`
	// pipeline's `:accepts ["json"]` matcher; offering `application/json` as the
	// negotiable fallback keeps the request off the 406 path (AcceptBarkparkVendor
	// appends json for a bare x-tar too, but a spec-clean Accept states both).
	req.Header.Set("Accept", "application/x-tar, application/json")

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

	// Stream to a TEMP file beside the destination and rename only after the
	// bytes check out. `os.Create(outPath)` truncated the destination BEFORE the
	// first byte arrived, so a network drop mid-transfer destroyed the backup the
	// export was supposed to replace — on the one verb whose entire promise is
	// that a backup is safe (PDS-D369). Same directory means same filesystem,
	// which is what makes the rename atomic.
	destDir := filepath.Dir(outPath)
	tmp, ferr := os.CreateTemp(destDir, "."+filepath.Base(outPath)+".part-*")
	if ferr != nil {
		return useError(out, "failed", "create temp export file in "+destDir+": "+ferr.Error(), exitGeneric)
	}
	tmpName := tmp.Name()
	n, cerr := io.Copy(tmp, resp.Body)
	if syncErr := tmp.Sync(); syncErr != nil && cerr == nil {
		cerr = syncErr
	}
	if closeErr := tmp.Close(); closeErr != nil && cerr == nil {
		cerr = closeErr
	}

	// What the server DECLARED, against what we actually received. resp.ContentLength
	// is -1 whenever Go's transport transparently decompressed the body (it adds
	// `Accept-Encoding: gzip` itself and then strips the length) or the response
	// was chunked — on THIS route the controller ends in send_file/2 and the stack
	// refuses to gzip application/x-tar, so a real length arrives today. But
	// PDS-D204 already moved this route send_resp -> send_file once; a move back
	// re-arms the -1 case, and a naive `n != resp.ContentLength` would then fail
	// EVERY successful export. So -1 is unverified-but-fine, PERMANENTLY, and a
	// real declared length that disagrees is a NAMED failure.
	declared := resp.ContentLength
	verified := declared >= 0 && n == declared
	if declared >= 0 && n != declared {
		os.Remove(tmpName)
		why := fmt.Sprintf("export size mismatch: server declared %d bytes, received %d", declared, n)
		if cerr != nil {
			why += " (" + cerr.Error() + ")"
		}
		why += "; " + exportDest(outPath) + " left unchanged"
		return useError(out, "failed", why, exitGeneric)
	}
	if cerr != nil {
		os.Remove(tmpName)
		return useError(out, "failed", "write export file: "+cerr.Error()+"; "+exportDest(outPath)+" left unchanged", exitGeneric)
	}
	if rerr := os.Rename(tmpName, outPath); rerr != nil {
		os.Remove(tmpName)
		return useError(out, "failed", "move export into place: "+rerr.Error(), exitGeneric)
	}

	payload := map[string]any{"workspace": slug, "file": outPath, "bytes": n, "verified": verified}
	if declared >= 0 {
		payload["declared_bytes"] = declared
	}
	if !out.machineOut() {
		out.outf("Exported workspace %s → %s (%s)", slug, outPath, humanBytes(float64(n)))
	}
	if verified {
		out.progressf("  %s — %d bytes fetched, size-verified against the server's declared length", outPath, n)
	} else {
		// NOT a failure and NOT a pass — the same honest third state the blob
		// sidecar reports for a NULL media_files.size (fetchWorkspaceBlobs). The
		// transfer stands; the verification does not.
		out.progressf("  %s — declared size absent; %d bytes fetched, unverified", outPath, n)
	}

	// Blob sidecar: DB rows are in the tar, the bytes are not. Run it after the
	// bundle receipt so the human view reads in the order things happened, and
	// fold its counts into the machine payload so a scripted caller sees one
	// document describing the whole pull.
	code := exitOK
	if withBlobs {
		rep := fetchWorkspaceBlobs(out, base, token, outPath, blobDir)
		payload["blobs"] = rep.payload()
		code = rep.exit
	}

	if out.emitStructured(payload) {
		return code
	}
	return code
}

// exportDatasetScope resolves the export's dataset grain from argv, and ONLY
// from argv.
//
// `-d/--dataset` is a GLOBAL value flag (globals.go valueFlags): parseGlobals
// consumes it wherever it appears in the command line, so this verb's own
// `dataset` flag resolves empty for every spelling a user actually types
// (`--dataset x`, `--dataset=x`, a leading `-d x`) and the value lands in
// g.dataset instead. Reading the local flag alone made `--dataset` a SILENT
// NO-OP: the request went out as `?profile=dev`, the bundle came back
// workspace-grain wearing a dataset-scoped command line, and on import
// stamp_provenance keyed the stamp by the bundle's dataset_slugs — never the
// `production` the imported rows actually carry — leaving the Bootstrap clobber
// guard inert for every pulled schema (PDS-D62).
//
// The fallback is GATED on g.datasetSet rather than on g.dataset being non-empty
// (the trap in cloud_site_cmd.go:163's version): the resolved context carries an
// ambient dataset from the saved config / BARKPARK_DATASET, and an unflagged
// full-workspace pull that silently narrowed itself to the operator's saved
// dataset would be the same class of silent wrong answer, pointed the other way.
// No flag typed → no dataset param → the server's whole-workspace default, the
// shape an unflagged export has always had.
func exportDatasetScope(g globals, a *hzArgs) string {
	if local := strings.TrimSpace(a.val("dataset")); local != "" {
		return local
	}
	if g.datasetSet {
		return strings.TrimSpace(g.dataset)
	}
	return ""
}

// bundleScopeQuery renders the export scope query string from
// --profile/--dataset/--source-server. Empty values are OMITTED entirely (not
// sent as blanks) so the server's own defaults — profile=full, whole-workspace
// grain, no provenance passthrough — stay the shape an un-flagged export has
// always had, byte-identical to the shipped B2 request.
//
// source_server is provenance, not scope: the server stamps it into the bundle
// manifest verbatim (workspace_controller.export → WorkspaceBundle opts), and
// without it every CLI-taken bundle recorded `source_server: null` — a pull
// receipt that could not name where the data came from.
func bundleScopeQuery(profile, dataset, sourceServer string) string {
	q := url.Values{}
	if p := strings.TrimSpace(profile); p != "" {
		q.Set("profile", p)
	}
	if d := strings.TrimSpace(dataset); d != "" {
		q.Set("dataset", d)
	}
	if s := strings.TrimSpace(sourceServer); s != "" {
		q.Set("source_server", s)
	}
	if len(q) == 0 {
		return ""
	}
	return "?" + q.Encode()
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
	const usage = "bp cloud workspace import <slug> --file <tar> --yes [--merge] [--with-blobs [--blobs <dir>]]"
	a, err := parseHzArgs(args, []string{"file", "blobs"}, []string{"merge", "with-blobs"}, usage)
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

	withBlobs := a.bools["with-blobs"]
	blobDir := strings.TrimSpace(a.val("blobs"))
	if blobDir == "" {
		blobDir = file + ".blobs"
	}

	base, token := workspaceBundleTarget(g)
	url := base + "/api/workspaces/" + slug + "/import"
	mode := "clean (restore)"
	if a.bools["merge"] {
		url += "?mode=merge"
		mode = "merge"
	}

	// Preview default: --dry-run (or the global --dry-run) prints the request and
	// sends nothing. This is checked BEFORE the --yes gate so an operator can
	// always preview a destructive import without first arming it.
	if g.dryRun {
		out.progressf("DRY RUN — would POST %s (%s) → %s", file, url, "RESTORE into workspace "+slug+" [mode: "+mode+"]")
		if withBlobs {
			out.progressf("DRY RUN — would then PUT each blob under %s to %s/api/workspaces/%s/media/blob/<path>", blobDir, base, slug)
		}
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

	// Cloud-target line: DEFENSE IN DEPTH, never the enforcement. Like `bp
	// migrate`'s --yes warning it is advisory — it names what is about to be
	// written and to where, and then proceeds. The actual refusal lives
	// server-side (403 bundle_import_disabled unless :allow_bundle_import is on).
	if warn := cloudTargetWarning(base, slug); warn != "" {
		out.errf("%s", warn)
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

	// "The receipt IS the contract" is exactly why it has to be READABLE first:
	// renderRaw echoes whatever arrived, so an HTML proxy page on a 200 was
	// handed to a machine consumer as the import receipt at rc=0, and the human
	// branch's importCounts({}) reported `0 row(s) across 0 table(s)` as a
	// completed import.
	if rc, handled := screenBuiltinWriteReceipt(out, "workspace import", resp.StatusCode, body); handled {
		return rc
	}

	// Machine consumers get the response bytes verbatim (the receipt IS the
	// contract). The human view names the workspace and the {tables,total_rows}
	// the engine reported.
	if out.machineOut() {
		out.renderRaw(body)
	} else {
		tables, rows := importCounts(body)
		out.outf("Imported workspace %s — %s across %s", slug, pluralize(rows, "row"), pluralize(tables, "table"))
		// The provenance receipt is CONDITIONAL: a server that stamps it gets it
		// printed, an older server that does not is silent — never a fabricated
		// line. Machine consumers already have the key verbatim in the body.
		printProvenanceReceipt(out, body)
	}

	if !withBlobs {
		return exitOK
	}
	rep := uploadWorkspaceBlobs(out, base, token, slug, blobDir)
	return rep.exit
}

// cloudTargetWarning returns the advisory line to print before writing into a
// CLOUD-classified target, or "" for a local one. It reads the saved config's
// explicit kind pin for the entry when the URL is a known server (cfg.KindOf),
// falling back to the dependency-free host classifier (ServerKind) for a raw
// URL. UX ONLY — it never refuses; the server's :allow_bundle_import opt-in is
// the enforcement.
func cloudTargetWarning(base, slug string) string {
	kind := ServerKind(base)
	if cfg, err := LoadConfig(); err == nil {
		if e, ok := cfg.FindServer(base); ok {
			kind = cfg.KindOf(e)
		}
	}
	if kind != "cloud" {
		return ""
	}
	return fmt.Sprintf("⚠ importing bundle content into workspace %q on %s [cloud] — this writes to a REMOTE server", slug, base)
}

// printProvenanceReceipt prints the import response's `provenance` block when the
// server stamped one: where the bundle came from, at what grain, under which
// scrub profile, and when it was pulled. Absent key → absolute silence (an older
// server, or a route that does not stamp — either way there is nothing honest to
// say). Known fields print in a fixed narrative order; anything else the server
// adds later still prints, sorted, rather than being swallowed.
func printProvenanceReceipt(out *writer, body []byte) {
	var r struct {
		Provenance map[string]any `json:"provenance"`
	}
	if err := json.Unmarshal(body, &r); err != nil || len(r.Provenance) == 0 {
		return
	}
	order := []string{"source_server", "source", "source_workspace", "workspace", "source_dataset", "dataset", "profile", "pulled_at"}
	seen := map[string]bool{}
	var lines []string
	add := func(k string) {
		v, ok := r.Provenance[k]
		if !ok || seen[k] || v == nil {
			return
		}
		seen[k] = true
		lines = append(lines, fmt.Sprintf("  %-16s %v", k+":", v))
	}
	for _, k := range order {
		add(k)
	}
	var rest []string
	for k := range r.Provenance {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	for _, k := range rest {
		add(k)
	}
	if len(lines) == 0 {
		return
	}
	out.outf("Provenance")
	for _, l := range lines {
		out.outf("%s", l)
	}
}

// importCounts pulls the {tables,total_rows} pair from the import receipt.
//
// `tables` is a MAP of table name → row count, not a number: the engine
// typespecs it that way (workspace_bundle.ex:182) and both import arms send
// `tables: stats.tables` verbatim (workspace_controller.ex:330, :348). The
// table COUNT is therefore the map's size.
//
// Each field is assigned INDEPENDENTLY of the unmarshal error, and that is
// load-bearing: encoding/json records the first type error and keeps decoding,
// so a receipt this client cannot fully read still yields the half that decoded
// (an older server sending a bare integer `tables` prints its real row count
// with an em dash for tables). Guarding the whole read on `err == nil` threw
// that half away and printed a double em dash on EVERY human-mode import.
// A field the client could not read stays -1 so the caller prints an em dash —
// never a fabricated zero.
func importCounts(body []byte) (tables, rows int) {
	var r struct {
		Tables    map[string]int `json:"tables"`
		TotalRows *int           `json:"total_rows"`
	}
	tables, rows = -1, -1
	_ = json.Unmarshal(body, &r)
	if r.Tables != nil {
		tables = len(r.Tables)
	}
	if r.TotalRows != nil {
		rows = *r.TotalRows
	}
	return tables, rows
}

// pluralize renders "<n> <noun>[s]" with an honest em dash when the count is
// unknown (-1 — a receipt whose field the client could not read, or that omitted
// it), never a fabricated zero.
func pluralize(n int, noun string) string {
	if n < 0 {
		return "— " + noun + "s"
	}
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// ── Blob sidecar ─────────────────────────────────────────────────────────────

// blobReport is the honest outcome of one sidecar run: how many blobs moved, how
// many did NOT, the failures NAMED, and the exit code the command must carry.
// The exit is the first failure's classified exit (so a 422 invalid_path stays a
// validation exit, a 404 stays not-found) — never a blanket 1 that erases what
// the server said.
type blobReport struct {
	verb     string // "fetched" | "uploaded"
	moved    int
	failed   int
	bytes    int64
	verified int // blobs whose byte count was checked against an independent number
	unknown  int // blobs that moved with NOTHING to check the byte count against
	dir      string
	failures []string
	exit     int
}

// payload renders the report for -o json/-o yaml.
func (r blobReport) payload() map[string]any {
	return map[string]any{
		r.verb:           r.moved,
		"failed":         r.failed,
		"bytes":          r.bytes,
		"size_verified":  r.verified,
		"size_unchecked": r.unknown,
		"dir":            r.dir,
		"failures":       r.failures,
	}
}

// bytesPhrase names the byte total with the EXACT strength of the claim behind
// it — the whole point of the sidecar verify is that it must not overstate.
//
//   - uploaded: the number is what the target says it RECEIVED
//     (media_controller.ex:247-251 echoes `byte_size(body)`, measured BEFORE
//     Blobstore.put_bytes/3, which returns a bare `:ok` with no stat read-back).
//     "stored" would be a claim nobody measured.
//   - fetched: the number is what io.Copy wrote to disk, of which `verified` were
//     checked against the bundle's declared media_files.size. `size` is NULLABLE
//     (a blob pushed by put_blob/2 creates no media_files row), so blobs with no
//     declared size are reported as unchecked rather than counted as proof.
func (r blobReport) bytesPhrase() string {
	if r.verb == "uploaded" {
		return fmt.Sprintf("%d bytes received by the target", r.bytes)
	}
	s := fmt.Sprintf("%d bytes, %d size-verified", r.bytes, r.verified)
	if r.unknown > 0 {
		s += fmt.Sprintf(", %d with no declared size", r.unknown)
	}
	return s
}

// fail records a NAMED per-blob failure and pins the exit to the first one seen.
func (r *blobReport) fail(out *writer, blobPath, why string, exit int) {
	r.failed++
	r.failures = append(r.failures, blobPath+": "+why)
	out.userErr("blob %s — %s", blobPath, why)
	if r.exit == exitOK {
		r.exit = exit
	}
}

// render writes the per-run summary line. It is a progress line (stderr under
// -o json/yaml) so machine stdout stays one parseable document.
func (r blobReport) render(out *writer) {
	out.progressf("Blobs: %d %s, %d failed, %s → %s", r.moved, r.verb, r.failed, r.bytesPhrase(), r.dir)
}

// fetchWorkspaceBlobs is the EXPORT half of the sidecar: read the bundle's
// `tables/media_files.copy` member for the server-generated relative paths, then
// GET each one from <source>/media/files/<path> into <dir>/<path>, streaming one
// file at a time. A bundle with no media_files member (or no rows) is not an
// error — it reports 0 and exits clean.
func fetchWorkspaceBlobs(out *writer, base, token, bundlePath, dir string) blobReport {
	rep := blobReport{verb: "fetched", dir: dir, exit: exitOK}
	refs, err := bundleMediaRefs(bundlePath)
	if err != nil {
		out.userErr("read media paths from %s: %v", bundlePath, err)
		rep.exit = exitGeneric
		rep.failed = 1
		rep.failures = append(rep.failures, bundlePath+": "+err.Error())
		return rep
	}
	if len(refs) == 0 {
		rep.render(out)
		return rep
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		out.userErr("create blob dir %s: %v", dir, err)
		rep.exit = exitGeneric
		rep.failed = 1
		rep.failures = append(rep.failures, dir+": "+err.Error())
		return rep
	}

	client := newTransferClient()
	for _, ref := range refs {
		p := ref.path
		if !safeBlobPath(p) {
			rep.fail(out, p, "refusing an unsafe media path (traversal/absolute/empty)", exitValidation)
			continue
		}
		dest := filepath.Join(dir, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
			rep.fail(out, p, "create directory: "+err.Error(), exitGeneric)
			continue
		}
		n, verified, ferr, exit := fetchOneBlob(client, base, token, ref, dest)
		if ferr != nil {
			rep.fail(out, p, ferr.Error(), exit)
			continue
		}
		rep.moved++
		rep.bytes += n
		if verified {
			rep.verified++
		} else {
			// NOT a failure and NOT a pass: media_files.size is nullable, so there
			// is genuinely nothing to check these bytes against. Saying so is the
			// whole difference between a verify and a vacuous green.
			rep.unknown++
			out.progressf("  %s — declared size absent; %d bytes fetched, unverified", p, n)
		}
	}
	rep.render(out)
	return rep
}

// fetchOneBlob GETs a single blob and STREAMS it to dest — io.Copy, never the
// whole file in memory. A non-2xx goes through the shared classifyError seam so
// the server's coded envelope picks the exit, not the HTTP status.
//
// The bytes written are compared against the bundle's own declared
// media_files.size for this row. A disagreement is a NAMED failure — a truncated
// blob that reported success is exactly the "success while wrong" this leg
// exists to catch. A row with NO declared size (the column is nullable) returns
// verified=false: the transfer stands, the verification does not.
//
// Any failure after the destination is opened REMOVES it: the sidecar directory
// is the import half's input, so short bytes left under the final name come
// back as an upload (PDS-D394).
func fetchOneBlob(client *http.Client, base, token string, ref mediaBlobRef, dest string) (int64, bool, error, int) {
	req, rerr := http.NewRequest(http.MethodGet, base+"/media/files/"+escapeBlobPath(ref.path), nil)
	if rerr != nil {
		return 0, false, rerr, exitGeneric
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, derr := client.Do(req)
	if derr != nil {
		return 0, false, derr, exitGeneric
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := readCapped(resp.Body, maxResponseBytes)
		ae := classifyError(resp.StatusCode, body)
		return 0, false, fmt.Errorf("%s", ae.errorMessage()), ae.exit
	}
	f, cerr := os.Create(dest)
	if cerr != nil {
		return 0, false, cerr, exitGeneric
	}
	n, copyErr := io.Copy(f, resp.Body)
	if closeErr := f.Close(); closeErr != nil && copyErr == nil {
		copyErr = closeErr
	}
	if copyErr != nil {
		// The bytes on disk are short and they sit under the FINAL name: the
		// import half walks this same sidecar directory and would PUT the
		// truncated file straight back. A named failure that leaves the bad
		// bytes in place is only half honest.
		_ = os.Remove(dest)
		return 0, false, copyErr, exitGeneric
	}
	if !ref.sizeKnown {
		return n, false, nil, exitOK
	}
	if n != ref.size {
		_ = os.Remove(dest)
		return 0, false, fmt.Errorf("size mismatch: bundle declares %d bytes, fetched %d", ref.size, n), exitGeneric
	}
	return n, true, nil, exitOK
}

// uploadWorkspaceBlobs is the IMPORT half: walk the sidecar dir and PUT every
// file back path-verbatim (its path RELATIVE to the sidecar dir is exactly the
// media_files.path the source served it under) to
// <target>/api/workspaces/<slug>/media/blob/<path>, one at a time. A missing
// sidecar dir is a NAMED failure, not a silent success — --with-blobs was asked
// for, so an absent media set is a lie the operator must see.
func uploadWorkspaceBlobs(out *writer, base, token, slug, dir string) blobReport {
	rep := blobReport{verb: "uploaded", dir: dir, exit: exitOK}
	paths, err := sidecarBlobPaths(dir)
	if err != nil {
		out.userErr("read blob dir %s: %v", dir, err)
		rep.failed = 1
		rep.failures = append(rep.failures, dir+": "+err.Error())
		rep.exit = exitGeneric
		return rep
	}
	if len(paths) == 0 {
		rep.render(out)
		return rep
	}

	client := newTransferClient()
	for _, p := range paths {
		if !safeBlobPath(p) {
			rep.fail(out, p, "refusing an unsafe media path (traversal/absolute/empty)", exitValidation)
			continue
		}
		n, uerr, exit := putOneBlob(client, base, token, slug, filepath.Join(dir, filepath.FromSlash(p)), p)
		if uerr != nil {
			rep.fail(out, p, uerr.Error(), exit)
			continue
		}
		rep.moved++
		rep.bytes += n
		rep.verified++
	}
	rep.render(out)
	return rep
}

// putOneBlob streams ONE sidecar file to the blob-push route. The body is the
// open file handle (net/http streams it; ContentLength comes from the stat), so
// the client never holds a whole asset in RAM — though the SERVER does cap the
// body at 100 MB (media_controller's read_full_body and endpoint.ex:124 both use
// 100_000_000), so anything larger comes back as an honest 413. Non-2xx rides
// classifyError — which is why `invalid_path` and `empty_body` now carry
// exitValidation in codeExit.
//
// The returned count is the TARGET's echoed byte count, never the local stat: a
// PUT that returned 2xx while the target received a different number of bytes is
// a NAMED failure. The echo is measured before the write hits the blobstore
// (Blobstore.put_bytes/3 returns a bare `:ok`), so it proves bytes RECEIVED —
// the caller's wording must not upgrade that to "stored".
func putOneBlob(client *http.Client, base, token, slug, localPath, blobPath string) (int64, error, int) {
	f, oerr := os.Open(localPath)
	if oerr != nil {
		return 0, oerr, exitGeneric
	}
	defer f.Close()
	fi, serr := f.Stat()
	if serr != nil {
		return 0, serr, exitGeneric
	}
	target := base + "/api/workspaces/" + slug + "/media/blob/" + escapeBlobPath(blobPath)
	req, rerr := http.NewRequest(http.MethodPut, target, f)
	if rerr != nil {
		return 0, rerr, exitGeneric
	}
	req.ContentLength = fi.Size()
	req.Header.Set("Authorization", "Bearer "+token)
	// octet-stream is load-bearing: a JSON content-type lets Plug.Parsers eat the
	// body and the route answers 422 empty_body.
	req.Header.Set("Content-Type", "application/octet-stream")

	resp, derr := client.Do(req)
	if derr != nil {
		return 0, derr, exitGeneric
	}
	defer resp.Body.Close()
	body, _ := readCapped(resp.Body, maxResponseBytes)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		ae := classifyError(resp.StatusCode, body)
		return 0, fmt.Errorf("%s", ae.errorMessage()), ae.exit
	}
	var echo struct {
		Bytes *int64 `json:"bytes"`
	}
	_ = json.Unmarshal(body, &echo)
	if echo.Bytes == nil {
		return 0, fmt.Errorf("target accepted the blob but echoed no byte count — the transfer cannot be verified"), exitGeneric
	}
	if *echo.Bytes != fi.Size() {
		return 0, fmt.Errorf("byte mismatch: sent %d bytes, target received %d", fi.Size(), *echo.Bytes), exitGeneric
	}
	return *echo.Bytes, nil, exitOK
}

// sidecarBlobPaths lists every regular file under dir as a SLASH-separated path
// relative to dir — the shape the source served it under, and therefore the shape
// the target must receive it under.
func sidecarBlobPaths(dir string) ([]string, error) {
	var paths []string
	err := filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, rerr := filepath.Rel(dir, p)
		if rerr != nil {
			return rerr
		}
		paths = append(paths, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(paths)
	return paths, nil
}

// mediaBlobRef is one blob the bundle says exists: the server-generated relative
// path, and the size the bundle DECLARES for it. sizeKnown is false when the row
// carries `\N` (media_files.size is nullable — Media.put_blob/2 writes bytes and
// creates no row at all) or when the bundle predates the size column; in that
// case there is nothing to verify a fetch against, and the CLI says so instead
// of pretending.
type mediaBlobRef struct {
	path      string
	size      int64
	sizeKnown bool
}

// bundleMediaRefs reads a bp-export-v1 tar and returns the media_files rows'
// (path, declared size) pairs, de-duplicated by path and sorted. The COLUMN
// ORDER is taken from the manifest's own member entry (never assumed
// positionally), and the dump is the raw Postgres `COPY … TO STDOUT` text
// format, so fields are tab-separated with backslash escapes and `\N` for NULL.
// A bundle with no media_files member — a legitimate shape for a workspace that
// has never uploaded anything — yields an empty list, not an error; a bundle
// whose member declares no `size` column yields refs with sizeKnown=false rather
// than an error, since the paths are still transferable.
func bundleMediaRefs(bundlePath string) ([]mediaBlobRef, error) {
	f, err := os.Open(bundlePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var manifestBytes, dumpBytes []byte
	tr := tar.NewReader(f)
	for {
		h, nerr := tr.Next()
		if nerr == io.EOF {
			break
		}
		if nerr != nil {
			return nil, fmt.Errorf("read bundle tar: %w", nerr)
		}
		name := path.Clean(h.Name)
		switch name {
		case "manifest.json":
			b, rerr := readCapped(tr, maxResponseBytes)
			if rerr != nil {
				return nil, fmt.Errorf("read manifest.json: %w", rerr)
			}
			manifestBytes = b
		case "tables/media_files.copy":
			b, rerr := readCapped(tr, maxResponseBytes)
			if rerr != nil {
				return nil, fmt.Errorf("read tables/media_files.copy: %w", rerr)
			}
			dumpBytes = b
		}
	}
	if len(manifestBytes) == 0 {
		return nil, fmt.Errorf("bundle has no manifest.json — not a bp-export-v1 tar")
	}
	if len(dumpBytes) == 0 {
		// No media member (or an empty one): honestly zero blobs.
		return nil, nil
	}
	idx, err := manifestColumnIndex(manifestBytes, "media_files", "path")
	if err != nil {
		return nil, err
	}
	// A missing size column is a bundle shape, not an error: -1 means "nothing
	// declared", and every ref comes back sizeKnown=false.
	sizeIdx, serr := manifestColumnIndex(manifestBytes, "media_files", "size")
	if serr != nil {
		sizeIdx = -1
	}
	return copyMediaRefs(dumpBytes, idx, sizeIdx), nil
}

// manifestColumnIndex finds a column's position in a manifest table member's
// declared column list — the arbiter of the dump's field order.
func manifestColumnIndex(manifestBytes []byte, table, column string) (int, error) {
	var m struct {
		Tables []struct {
			Name    string   `json:"name"`
			Columns []string `json:"columns"`
		} `json:"tables"`
	}
	if err := json.Unmarshal(manifestBytes, &m); err != nil {
		return 0, fmt.Errorf("parse manifest.json: %w", err)
	}
	for _, t := range m.Tables {
		if t.Name != table {
			continue
		}
		for i, c := range t.Columns {
			if c == column {
				return i, nil
			}
		}
		return 0, fmt.Errorf("manifest %s member declares no %q column", table, column)
	}
	return 0, fmt.Errorf("manifest declares no %s member", table)
}

// copyMediaRefs pulls the (path, size) pair out of a Postgres COPY-text dump:
// rows are newline-separated (a literal newline inside a value is escaped as \n,
// so a raw split is safe), fields are tab-separated, and `\N` is NULL — a NULL
// path is skipped (no blob to move), a NULL or unparseable size yields
// sizeKnown=false (there is simply nothing to verify against). sizeIdx < 0 means
// the manifest declared no size column at all.
func copyMediaRefs(dump []byte, idx, sizeIdx int) []mediaBlobRef {
	seen := map[string]bool{}
	var refs []mediaBlobRef
	for _, line := range strings.Split(string(dump), "\n") {
		if line == "" || line == "\\." {
			continue
		}
		fields := strings.Split(line, "\t")
		if idx >= len(fields) {
			continue
		}
		raw := fields[idx]
		if raw == "\\N" {
			continue
		}
		v := unescapeCopyField(raw)
		if v == "" || seen[v] {
			continue
		}
		seen[v] = true
		ref := mediaBlobRef{path: v}
		if sizeIdx >= 0 && sizeIdx < len(fields) && fields[sizeIdx] != "\\N" {
			if n, err := strconv.ParseInt(strings.TrimSpace(fields[sizeIdx]), 10, 64); err == nil && n >= 0 {
				ref.size, ref.sizeKnown = n, true
			}
		}
		refs = append(refs, ref)
	}
	sort.Slice(refs, func(i, j int) bool { return refs[i].path < refs[j].path })
	return refs
}

// unescapeCopyField reverses the Postgres COPY-text backslash escapes.
func unescapeCopyField(s string) string {
	if !strings.ContainsRune(s, '\\') {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'b':
			b.WriteByte('\b')
		case 'f':
			b.WriteByte('\f')
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case 'v':
			b.WriteByte('\v')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// safeBlobPath is the CLIENT-side fence on a media path before it becomes a
// filesystem destination or a URL segment: relative, non-empty, no traversal, no
// Windows separator. The server's own per-segment allowlist is the authority
// (422 invalid_path); this stops a hostile bundle from writing outside the
// sidecar dir on the way there.
func safeBlobPath(p string) bool {
	if strings.TrimSpace(p) == "" || strings.HasPrefix(p, "/") || strings.ContainsAny(p, "\\\x00") {
		return false
	}
	if strings.Contains(p, "://") {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return false
		}
	}
	return true
}

// escapeBlobPath percent-escapes each segment of a media path for the URL while
// keeping the `/` structure — the path the target stores must be byte-identical
// to the source's, so nothing is normalised away.
func escapeBlobPath(p string) string {
	segs := strings.Split(p, "/")
	for i, s := range segs {
		segs[i] = url.PathEscape(s)
	}
	return strings.Join(segs, "/")
}

// printCloudWorkspaceHelp writes `bp cloud workspace` usage.
func printCloudWorkspaceHelp(out *writer) {
	const help = `bp cloud workspace — export/import a single workspace as a portable bundle.

USAGE
  bp cloud workspace export <slug> [--file <out>] [--profile full|dev]
                                   [--dataset <slug>] [--source-server <url>]
                                   [--with-blobs [--blobs <dir>]]
  bp cloud workspace import <slug>  --file <tar> --yes [--merge]
                                   [--with-blobs [--blobs <dir>]]

EXPORT
  GETs /api/workspaces/<slug>/export and streams the tar to <out> (default
  <slug>.tar, or ` + "`-`" + ` for stdout). Read-only. The bundle is a bp-export-v1 tar
  (manifest.json + per-table COPY dumps) scoped to the one workspace — the Go
  twin of the shipped Barkpark.Tenancy.WorkspaceBundle engine.
    --profile dev    scrub secrets AT export (the personal-dev-server profile);
                     ` + "`full`" + ` (the default) stays byte-identical to an unflagged pull
    --dataset <slug> narrow the bundle to one dataset partition. This is the same
                     name as the GLOBAL -d/--dataset, which the global parser
                     claims wherever it appears — so every spelling
                     (` + "`--dataset x`" + `, ` + "`--dataset=x`" + `, a leading ` + "`-d x`" + `) means the same
                     thing here. Only a TYPED flag scopes the bundle: a dataset
                     merely saved in your config never narrows an export.
    --source-server <url>
                     provenance passthrough — stamped into the bundle manifest
                     so the import receipt can name where the data came from
  All three map straight to server query params — omitted when not passed, so an
  unflagged export sends the exact request it always has.

IMPORT
  POSTs the tar body to /api/workspaces/<slug>/import, which RESTORES the bundle
  into the workspace scope. The engine assumes a CLEAN target — E3/allowlist
  members are ON CONFLICT idempotent, but the copy-strategy members collide
  against existing content, so restore into an empty scope. Because it writes it
  is gated:
    --dry-run   preview the request, send nothing (also honoured via the global --dry-run)
    --yes       required to actually apply — without it the command refuses
    --merge     send ?mode=merge (upsert into a live workspace). The SERVER is the
                enforcement: mode=merge is refused 403 bundle_import_disabled
                unless the operator opted in via :allow_bundle_import.
  On success it prints the {tables,total_rows} the engine reported, plus the
  provenance receipt (source / dataset / profile / pulled_at) when the server
  stamped one.
  A cloud-classified target earns a warning line before the write. That warning
  is ADVISORY — like ` + "`bp migrate --yes`" + ` it never refuses; the refusal is the
  server-side opt-in above.

BLOBS
  The bundle is DB-only — it carries no media bytes. ` + "`--with-blobs`" + ` runs the
  sidecar channel on either verb:
    export  parses tables/media_files.copy, GETs each path from
            <source>/media/files/<path> into <bundle>.blobs/ (or --blobs <dir>)
    import  PUTs every file under that dir path-verbatim to
            <target>/api/workspaces/<slug>/media/blob/<path>
  One file at a time, streamed — never the whole set in RAM. The report names
  every failure and the command exits NON-ZERO if any blob failed.

TRANSPORT
  Plain HTTP to the CONTENT API — the configured server (` + "`-s`" + `/BARKPARK_API_URL)
  and its admin bearer (` + "`--token`" + `/BARKPARK_API_TOKEN). The route is admin-only,
  so an absent token is refused up front. This is NOT the SSH instance-transfer
  seam and NOT the whole-instance bp-bundle-v1 archive.`
	out.outf("%s", help)
}
