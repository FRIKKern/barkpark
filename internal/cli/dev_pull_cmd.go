package cli

// dev_pull_cmd.go is `bp dev pull` — the single-verb, edge-to-edge PDS pull
// (roadmap G5). It is a COMPOSITION, never a rival transport: every byte still
// moves through the shipped `bp cloud workspace export|import` functions and the
// blob sidecar they already use (runCloudWorkspaceExport, fetchWorkspaceBlobs,
// runCloudWorkspaceImport, uploadWorkspaceBlobs). What this verb adds is the
// three things a two-command runbook cannot have:
//
//  1. TWO separately resolved server contexts, the way runMigrate resolves them
//     — both from SAVED SERVER ENTRIES, never from the ambient content context
//     and never from the environment. A mirrored `-s`/`--token` typo pointing a
//     production admin token at the target is the failure this closes.
//  2. A manifest GRAIN assertion between the two halves. A workspace-grain
//     bundle wearing a dataset command line imports perfectly and then every
//     downstream census silently describes the whole workspace (PDS-D61/D62).
//     The guard lived only in the shell harness (scripts/pds-pull-proof.sh
//     step 1, its manifest_field reader); bundleGrain is the Go port.
//  3. ONE receipt that DESCENDS from the import's own receipt — the target's
//     {tables,total_rows} body plus the two blob reports — and a NAMED,
//     resumable state for every way the pull can die.
//
// NO-CUSTOMER-CONTENT INVARIANT (the charter's hard rule). Content moves
// edge-to-edge over the direct content-API HTTP path only; the Cloud
// control-plane client (internal/cloudclient) is never imported into this
// transfer path. TestDevPullTransferPathNeverReachesControlPlaneClient walks the
// import graph from runDevPull and proves it, and proves in the same run that
// the walker CAN see the control plane when one is genuinely reachable.
//
// PHASES. Each phase names itself in every failure, so an operator never has to
// guess which half died or what survived on disk:
//
//	resolve → export → verify → export-blobs → import → import-blobs → reconcile
//
// A failure in ANY of them is a devPullFailure: the phase, what the sub-verb
// itself said, the bundle + sidecar paths that survive, whether the state is
// RESUMABLE (`--resume`, which skips the export) or merely SAFELY RESTARTABLE
// (re-run the whole command — the export writes through a temp file and renames,
// so a restart can never destroy the bundle it is replacing), and the exact
// command to type. Temporary artifacts are removed ONLY after a fully reconciled
// success; a failure always keeps them and says where they are.
//
// The verb NEVER reports a successful pull with missing members. The import half
// is not even attempted while a single blob fetch failed, and after the upload
// the two sidecar counts are RECONCILED — uploaded must equal fetched — so a
// partially-transferred media set is a non-zero exit with a named shortfall
// rather than a receipt with a footnote.

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// devPullUsage is the one usage string every arity/flag error quotes.
const devPullUsage = "bp dev pull <source-server> <target-server> <workspace>/<dataset> --yes [--bundle <path>] [--keep] [--resume]"

// devPullProfile is pinned, not a flag. The verb IS the dev pull: a `full`
// profile bundle carries unscrubbed content and has no business landing on a
// personal development server, and the grain assertion below refuses anything
// the manifest does not confirm as dev.
const devPullProfile = "dev"

// runDev routes `bp dev <verb> …`. `pull` is the only verb today; the namespace
// exists because the PDS developer loop (up · pull · reset · promote) is a set,
// and a one-verb noun that grows a sibling later should not move house.
func runDev(out *writer, g globals, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printDevHelp(out)
			return exitOK
		}
	}
	if len(args) == 0 {
		if g.help {
			printDevHelp(out)
			return exitOK
		}
		return useError(out, "usage", "missing dev command (run `bp dev -h` for usage)", exitUsage)
	}
	switch args[0] {
	case "pull":
		if g.help {
			printDevPullHelp(out)
			return exitOK
		}
		return runDevPull(out, g, args[1:])
	case "help":
		printDevHelp(out)
		return exitOK
	default:
		return useError(out, "usage", fmt.Sprintf("unknown dev command %q (run `bp dev -h` for usage)", args[0]), exitUsage)
	}
}

// ── the named failure state ──────────────────────────────────────────────────

// devPullFailure is the ONLY way this verb reports a non-success. It names the
// phase that died, what the underlying verb said, the artifacts that survive on
// disk, and the exact command that continues from here. `resumable` is the
// difference between "the bundle on disk is still the input, skip the export"
// and "start over — nothing on the target is half-written in a way a re-run
// cannot heal".
type devPullFailure struct {
	phase     string // resolve | export | verify | export-blobs | import | import-blobs | reconcile
	code      string // stable machine slug, e.g. dev_pull_export_failed
	why       string
	bundle    string // "" while no bundle landed
	blobs     string // "" while no sidecar landed
	rerun     string
	resumable bool
	imported  bool // did the target already take DB rows? (a partial target)
	exit      int
}

// render emits the failure. Machine mode gets the full state as `details` so a
// script can branch on the phase and re-run the named command without scraping
// prose; human mode gets the same facts as continuation lines.
func (f devPullFailure) render(out *writer) int {
	state := map[string]any{
		"phase":     f.phase,
		"resumable": f.resumable,
		"rerun":     f.rerun,
	}
	if f.bundle != "" {
		state["bundle"] = f.bundle
	}
	if f.blobs != "" {
		state["blobs"] = f.blobs
	}
	if f.imported {
		state["target_holds_rows"] = true
	}
	msg := "dev pull failed in the " + f.phase + " phase: " + f.why
	if out.machineOut() {
		det, err := json.Marshal(state)
		if err != nil {
			// A details block that will not marshal must never cost the caller
			// the refusal itself — report the failure without it.
			return useError(out, f.code, msg, f.exit)
		}
		return useErrorDetailed(out, f.code, msg, f.exit, det)
	}
	useError(out, f.code, msg, f.exit)
	if f.bundle != "" {
		out.errf("  bundle:    %s", f.bundle)
	}
	if f.blobs != "" {
		out.errf("  sidecar:   %s", f.blobs)
	}
	if f.imported {
		out.errf("  target:    already holds the bundle's DB rows — the media set is INCOMPLETE, so this is NOT a finished pull")
	}
	if f.resumable {
		out.errf("  resumable: yes — the bundle on disk is still the input")
	} else {
		out.errf("  resumable: no — safely restartable instead (the export writes through a temp file and renames, so a re-run never destroys the bundle it replaces)")
	}
	out.errf("  re-run:    %s", f.rerun)
	return f.exit
}

// ── the verb ─────────────────────────────────────────────────────────────────

// runDevPull is `bp dev pull <source> <target> <workspace>/<dataset>`. No
// @canonical marker: the name self-points, and the doctrine reserves the index
// for forked or jargon-named capabilities.
func runDevPull(out *writer, g globals, args []string) int {
	a, perr := parseHzArgs(args, []string{"bundle"}, []string{"keep", "resume", "yes"}, devPullUsage)
	if perr != nil {
		return useError(out, "usage", perr.Error(), exitUsage)
	}
	if len(a.pos) != 3 {
		return useError(out, "usage",
			fmt.Sprintf("want exactly <source-server> <target-server> <workspace>/<dataset> (usage: %s)", devPullUsage), exitUsage)
	}
	srcName, tgtName := a.pos[0], a.pos[1]
	ws, ds, serr := parseDevPullScope(a.pos[2])
	if serr != nil {
		return useError(out, "usage", serr.Error(), exitUsage)
	}
	if !validWorkspaceSlug(ws) {
		return useError(out, "usage", fmt.Sprintf("invalid workspace slug %q", ws), exitUsage)
	}
	resume := a.bools["resume"]
	keep := a.bools["keep"] || resume

	// ── phase: resolve ────────────────────────────────────────────────────────
	//
	// Both ends come from the SAVED SERVER CONFIG, the way runMigrate resolves
	// its two, and the credential is the entry's own token (or an explicit
	// --token). Nothing here reads the environment: a pull carries a PRODUCTION
	// admin token, and an ambient BARKPARK_* export silently supplying it — or
	// silently supplying the WRONG one — is the mirrored-typo hazard this verb
	// exists to close.
	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "dev_pull_config", "read config: "+cerr.Error(), exitGeneric)
	}
	srcEntry, ok := cfg.FindServer(srcName)
	if !ok {
		return devPullUnknownServer(out, cfg, srcName, "source")
	}
	tgtEntry, ok := cfg.FindServer(tgtName)
	if !ok {
		return devPullUnknownServer(out, cfg, tgtName, "target")
	}
	srcBase := strings.TrimRight(strings.TrimSpace(srcEntry.Server), "/")
	tgtBase := strings.TrimRight(strings.TrimSpace(tgtEntry.Server), "/")
	srcTok := firstNonEmptyStr(srcEntry.Token, g.token)
	tgtTok := firstNonEmptyStr(tgtEntry.Token, g.token)
	if srcTok == "" {
		return devPullNoToken(out, cfg.DisplayName(srcEntry), "source")
	}
	if tgtTok == "" {
		return devPullNoToken(out, cfg.DisplayName(tgtEntry), "target")
	}
	// Same box on both ends is never a pull. It is either a no-op or, with the
	// source token in hand, a restore of production onto itself.
	if srcBase == tgtBase {
		return useError(out, "dev_pull_same_server",
			fmt.Sprintf("source and target both resolve to %s — a pull needs two distinct servers", srcBase), exitUsage)
	}

	srcLabel, tgtLabel := cfg.DisplayName(srcEntry), cfg.DisplayName(tgtEntry)
	bundle, ownDir := devPullBundlePath(strings.TrimSpace(a.val("bundle")), srcLabel, ws, ds)
	blobDir := bundle + ".blobs"
	rerun := devPullRerunCmd(srcName, tgtName, ws, ds, bundle, false)
	rerunResume := devPullRerunCmd(srcName, tgtName, ws, ds, bundle, true)

	gSrc := devPullEndpointGlobals(g, srcBase, srcTok)
	gTgt := devPullEndpointGlobals(g, tgtBase, tgtTok)

	if g.dryRun {
		out.progressf("DRY RUN — would pull %s/%s (profile %s)", ws, ds, devPullProfile)
		out.progressf("  export  %s [%s] → %s", srcBase, srcLabel, bundle)
		out.progressf("  verify  the bundle manifest declares profile=%s dataset=%s", devPullProfile, ds)
		out.progressf("  blobs   → %s, then PUT each one to %s [%s]", blobDir, tgtBase, tgtLabel)
		out.progressf("  import  %s → workspace %s on %s [%s] (mode: merge)", bundle, ws, tgtBase, tgtLabel)
		return exitOK
	}

	// The import WRITES into the target workspace. The wrapper carries its own
	// --yes gate rather than inheriting the sub-verb's, so an operator arms the
	// whole pull once, deliberately, naming the box it writes to.
	if !(g.yes || a.bools["yes"]) {
		return useError(out, "usage",
			fmt.Sprintf("refusing to pull %s/%s into workspace %q on %s [%s] without --yes — this WRITES bundle content and media into it; pass --yes to proceed or --dry-run to preview",
				ws, ds, ws, tgtBase, tgtLabel), exitUsage)
	}

	if err := os.MkdirAll(filepath.Dir(bundle), 0o755); err != nil {
		return useError(out, "dev_pull_workdir", "create bundle directory "+filepath.Dir(bundle)+": "+err.Error(), exitGeneric)
	}

	// ── phase: export ─────────────────────────────────────────────────────────
	//
	// --with-blobs is deliberately NOT passed: the sidecar fetch runs as its own
	// phase below so an export that succeeded and a blob set that did not are
	// never reported as one indivisible outcome.
	exportBytes := int64(-1)
	if resume {
		if _, err := os.Stat(bundle); err != nil {
			return devPullFailure{
				phase: "resolve", code: "dev_pull_resume_missing",
				why:   "--resume was asked for but there is no bundle at " + bundle + " (" + err.Error() + ")",
				rerun: rerun, exit: exitNotFound,
			}.render(out)
		}
		out.progressf("Resuming from %s (export and blob fetch skipped)", bundle)
	} else {
		out.progressf("Exporting %s/%s from %s [%s] (profile %s)", ws, ds, srcBase, srcLabel, devPullProfile)
		code, doc := devPullSub(out, gSrc, []string{
			ws, "--file", bundle, "--profile", devPullProfile, "--dataset", ds, "--source-server", srcBase,
		}, runCloudWorkspaceExport)
		if code != exitOK {
			return devPullFailure{
				phase: "export", code: "dev_pull_export_failed",
				why:    devPullSubWhy(doc, "the export verb refused"),
				bundle: devPullSurviving(bundle),
				rerun:  rerun, exit: code,
			}.render(out)
		}
		exportBytes = devPullInt(doc, "bytes")
	}

	// ── phase: verify (the grain assertion) ───────────────────────────────────
	//
	// The port of the shell harness's manifest_field guard. A bundle whose
	// manifest carries NO dataset is WORKSPACE-GRAIN wearing a dataset command
	// line: it imports cleanly and every downstream count then describes the
	// whole workspace while the receipt claims one dataset. Refuse before a
	// single byte is imported, and keep the bundle so it can be inspected.
	profile, dataset, gerr := bundleGrain(bundle)
	if gerr != nil {
		return devPullFailure{
			phase: "verify", code: "dev_pull_manifest_unreadable",
			why:    "cannot read the bundle manifest: " + gerr.Error() + " — nothing was imported",
			bundle: bundle, rerun: rerun, exit: exitGeneric,
		}.render(out)
	}
	if dataset == "" {
		return devPullFailure{
			phase: "verify", code: "dev_pull_workspace_grain",
			why:    fmt.Sprintf("the exported manifest carries NO dataset field — this is a WORKSPACE-GRAIN bundle wearing a dataset command line (asked for dataset=%s). Refusing to import it: every count downstream would describe the whole workspace while this receipt claimed one dataset. Nothing was imported", ds),
			bundle: bundle, rerun: rerun, exit: exitValidation,
		}.render(out)
	}
	if dataset != ds {
		return devPullFailure{
			phase: "verify", code: "dev_pull_grain_mismatch",
			why:    fmt.Sprintf("the exported manifest says dataset=%q but the export asked for %q — the scope flag is not reaching the engine. Nothing was imported", dataset, ds),
			bundle: bundle, rerun: rerun, exit: exitValidation,
		}.render(out)
	}
	if profile != devPullProfile {
		return devPullFailure{
			phase: "verify", code: "dev_pull_profile_mismatch",
			why: fmt.Sprintf("the exported manifest says profile=%q but the export asked for %q — this bundle is NOT scrubbed and must not be treated as one. Nothing was imported",
				devPullEmptyAs(profile), devPullProfile),
			bundle: bundle, rerun: rerun, exit: exitValidation,
		}.render(out)
	}
	out.progressf("Manifest grain asserted: profile=%s dataset=%s", profile, dataset)

	// ── phase: export-blobs ───────────────────────────────────────────────────
	//
	// The bundle is DB-only. A single failed fetch stops the pull HERE: importing
	// rows whose media bytes never left the source is precisely the "success with
	// missing members" this verb must never produce.
	fetched, blobBytes := -1, int64(0)
	if !resume {
		rep := fetchWorkspaceBlobs(devPullQuietWriter(out), srcBase, srcTok, bundle, blobDir)
		if rep.failed > 0 {
			return devPullFailure{
				phase: "export-blobs", code: "dev_pull_blob_fetch_failed",
				why: fmt.Sprintf("%d of %d blob(s) did not leave the source (%s) — refusing to import a bundle whose media set is already short",
					rep.failed, rep.failed+rep.moved, strings.Join(rep.failures, "; ")),
				bundle: bundle, blobs: blobDir, rerun: rerun, exit: rep.exit,
			}.render(out)
		}
		fetched, blobBytes = rep.moved, rep.bytes
		out.progressf("Fetched %d blob(s) → %s", fetched, blobDir)
	}

	// ── phase: import ─────────────────────────────────────────────────────────
	//
	// --merge is MANDATORY and not a flag: mode=clean against a populated target
	// is the failure the whole PDS loop exists to avoid, and a re-run of a merge
	// pull IS the refresh. --with-blobs is again withheld so the upload is its
	// own phase.
	out.progressf("Importing %s → workspace %s on %s [%s] (mode: merge)", bundle, ws, tgtBase, tgtLabel)
	// --yes is a GLOBAL flag the import verb reads off g.yes (its own parser
	// rejects it as unknown), which is why devPullEndpointGlobals arms it there
	// and the argv below carries only the verb's own flags.
	code, receipt := devPullSub(out, gTgt, []string{ws, "--file", bundle, "--merge"}, runCloudWorkspaceImport)
	if code != exitOK {
		return devPullFailure{
			phase: "import", code: "dev_pull_import_failed",
			why:       devPullSubWhy(receipt, "the import verb refused"),
			bundle:    bundle,
			blobs:     devPullSurvivingDir(blobDir),
			rerun:     rerunResume,
			resumable: true,
			exit:      code,
		}.render(out)
	}
	tables, rows := importCounts(receipt)

	// ── phase: import-blobs ───────────────────────────────────────────────────
	uploaded, uploadedBytes := 0, int64(0)
	if devPullHasSidecar(blobDir) {
		rep := uploadWorkspaceBlobs(devPullQuietWriter(out), tgtBase, tgtTok, ws, blobDir)
		if rep.failed > 0 {
			return devPullFailure{
				phase: "import-blobs", code: "dev_pull_blob_upload_failed",
				why: fmt.Sprintf("the target took the DB rows but %d of %d blob(s) did not reach it (%s) — the pull is INCOMPLETE",
					rep.failed, rep.failed+rep.moved, strings.Join(rep.failures, "; ")),
				bundle: bundle, blobs: blobDir, rerun: rerunResume,
				resumable: true, imported: true, exit: rep.exit,
			}.render(out)
		}
		uploaded, uploadedBytes = rep.moved, rep.bytes
	}

	// ── phase: reconcile ──────────────────────────────────────────────────────
	//
	// Both sidecar halves reported zero failures; that is not the same claim as
	// "everything the source served reached the target". Only the two COUNTS
	// agreeing says that, and on a fresh pull both are known.
	if !resume && fetched >= 0 && uploaded != fetched {
		return devPullFailure{
			phase: "reconcile", code: "dev_pull_blob_shortfall",
			why: fmt.Sprintf("the source served %d blob(s) but only %d reached the target — the media set is short and this is NOT a finished pull",
				fetched, uploaded),
			bundle: bundle, blobs: blobDir, rerun: rerunResume,
			resumable: true, imported: true, exit: exitGeneric,
		}.render(out)
	}

	// ── the ONE receipt ───────────────────────────────────────────────────────
	//
	// Removal happens only HERE, after reconciliation: every failure above kept
	// its artifacts and named them.
	cleaned := false
	if ownDir && !keep {
		if err := os.RemoveAll(filepath.Dir(bundle)); err == nil {
			cleaned = true
		} else {
			out.errf("bp: could not remove the temporary bundle directory %s: %v", filepath.Dir(bundle), err)
		}
	}
	return devPullReceipt(out, devPullResult{
		source: srcLabel, sourceURL: srcBase, target: tgtLabel, targetURL: tgtBase,
		workspace: ws, dataset: dataset, profile: profile,
		bundle: bundle, bundleBytes: exportBytes, cleaned: cleaned, resumed: resume,
		tables: tables, rows: rows, receipt: receipt,
		blobsFetched: fetched, blobsUploaded: uploaded,
		blobBytes: blobBytes, uploadedBytes: uploadedBytes,
	})
}

// ── the receipt ──────────────────────────────────────────────────────────────

// devPullResult is everything the one receipt is allowed to say, and it is all
// MEASURED: the export's own byte count, the import's own {tables,total_rows}
// body, and the two blob reports. Nothing here is a constant, and there is no
// "ok" — a pull that cannot describe what moved has not earned a success line.
type devPullResult struct {
	source, sourceURL  string
	target, targetURL  string
	workspace, dataset string
	profile            string
	bundle             string
	bundleBytes        int64
	cleaned            bool
	resumed            bool
	tables, rows       int
	receipt            []byte
	blobsFetched       int
	blobsUploaded      int
	blobBytes          int64
	uploadedBytes      int64
}

func devPullReceipt(out *writer, r devPullResult) int {
	if out.machineOut() {
		payload := map[string]any{
			"source":    map[string]any{"name": r.source, "server": r.sourceURL},
			"target":    map[string]any{"name": r.target, "server": r.targetURL},
			"workspace": r.workspace,
			"dataset":   r.dataset,
			"profile":   r.profile,
			"mode":      "merge",
			"bundle":    map[string]any{"path": r.bundle, "removed": r.cleaned, "resumed": r.resumed},
			"blobs":     map[string]any{"fetched": r.blobsFetched, "uploaded": r.blobsUploaded, "bytes_fetched": r.blobBytes, "bytes_received": r.uploadedBytes},
		}
		if r.bundleBytes >= 0 {
			payload["bundle"].(map[string]any)["bytes"] = r.bundleBytes
		}
		// The import's OWN body, verbatim, is the spine of this document: the
		// wrapper's counts are DERIVED from it and must never replace it.
		var raw any
		if err := json.Unmarshal(r.receipt, &raw); err == nil {
			payload["import"] = raw
		} else {
			payload["import"] = map[string]any{
				"tables": r.tables, "total_rows": r.rows,
				"unreadable": "the target's receipt did not parse as JSON",
			}
		}
		out.emitStructured(payload)
		return exitOK
	}

	out.outf("Pulled %s/%s — %s [%s] → %s [%s]", r.workspace, r.dataset, r.source, r.sourceURL, r.target, r.targetURL)
	if r.resumed {
		out.outf("  bundle     %s (re-used; export and blob fetch skipped)", r.bundle)
	} else if r.bundleBytes >= 0 {
		out.outf("  bundle     %s, %s%s", humanBytes(float64(r.bundleBytes)), r.bundle, devPullCleanedNote(r.cleaned))
	} else {
		out.outf("  bundle     %s%s", r.bundle, devPullCleanedNote(r.cleaned))
	}
	out.outf("  imported   %s across %s (profile %s, mode merge)", pluralize(r.rows, "row"), pluralize(r.tables, "table"), r.profile)
	if r.tables < 0 && r.rows < 0 {
		// The target accepted the bundle and said nothing this client could read.
		// That is not a missing member and not a failure — but it is also not a
		// verification, and saying so is the difference from a vacuous green.
		out.outf("             the target accepted the bundle but its receipt named no counts — the transfer stands, the verification does not")
	}
	if r.resumed {
		out.outf("  blobs      %d uploaded from the re-used sidecar (%s received by the target)", r.blobsUploaded, humanBytes(float64(r.uploadedBytes)))
	} else {
		out.outf("  blobs      %d fetched, %d uploaded — reconciled (%s received by the target)",
			r.blobsFetched, r.blobsUploaded, humanBytes(float64(r.uploadedBytes)))
	}
	printProvenanceReceipt(out, r.receipt)
	return exitOK
}

func devPullCleanedNote(cleaned bool) string {
	if cleaned {
		return " (removed)"
	}
	return ""
}

// ── the grain guard (ported from scripts/pds-pull-proof.sh step 1) ───────────

// bundleGrain reads ONLY manifest.json out of the bundle tar and returns the
// profile and dataset it declares. Both come back empty when the manifest omits
// them — an ABSENT dataset is the workspace-grain signal the caller refuses on,
// so it must be reported as absent rather than defaulted into something
// plausible. A tar with no manifest at all is not a bp-export-v1 bundle and is
// an error, never an empty grain.
func bundleGrain(bundlePath string) (profile, dataset string, err error) {
	f, oerr := os.Open(bundlePath)
	if oerr != nil {
		return "", "", oerr
	}
	defer f.Close()

	tr := tar.NewReader(f)
	for {
		h, nerr := tr.Next()
		if nerr == io.EOF {
			break
		}
		if nerr != nil {
			return "", "", fmt.Errorf("read bundle tar: %w", nerr)
		}
		if path.Clean(h.Name) != "manifest.json" {
			continue
		}
		b, rerr := readCapped(tr, maxResponseBytes)
		if rerr != nil {
			return "", "", fmt.Errorf("read manifest.json: %w", rerr)
		}
		var m struct {
			Profile string `json:"profile"`
			Dataset string `json:"dataset"`
		}
		if jerr := json.Unmarshal(b, &m); jerr != nil {
			return "", "", fmt.Errorf("parse manifest.json: %w", jerr)
		}
		return strings.TrimSpace(m.Profile), strings.TrimSpace(m.Dataset), nil
	}
	return "", "", fmt.Errorf("bundle has no manifest.json — not a bp-export-v1 tar")
}

// ── plumbing ─────────────────────────────────────────────────────────────────

// parseDevPullScope splits `<workspace>/<dataset>`. The bundle route has exactly
// two grains — workspace and dataset — so a three-segment
// `<workspace>/<project>/<dataset>` is REFUSED by name rather than silently
// dropping the middle segment: a scope the transfer never honours must not be
// accepted as if it did.
func parseDevPullScope(s string) (workspace, dataset string, err error) {
	parts := strings.Split(strings.TrimSpace(s), "/")
	switch len(parts) {
	case 2:
		if strings.TrimSpace(parts[0]) == "" || strings.TrimSpace(parts[1]) == "" {
			return "", "", fmt.Errorf("scope %q needs both halves (usage: %s)", s, devPullUsage)
		}
		return strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1]), nil
	case 3:
		return "", "", fmt.Errorf("scope %q names a project, but the workspace bundle has only workspace and dataset grain — pass <workspace>/<dataset>", s)
	default:
		return "", "", fmt.Errorf("scope %q must be <workspace>/<dataset> (usage: %s)", s, devPullUsage)
	}
}

// devPullEndpointGlobals builds the globals one half of the pull runs under.
// server + token are PINNED at flag precedence, which is what keeps the
// environment out of a credential decision. The ambient dataset is cleared with
// its typed bit: the grain rides the sub-verb's own --dataset flag, and leaving
// g.datasetSet set would let a saved -d silently re-scope the bundle.
func devPullEndpointGlobals(g globals, base, token string) globals {
	sub := g
	sub.server = base
	sub.token = token
	sub.dataset = ""
	sub.datasetSet = false
	sub.help = false
	sub.dryRun = false
	sub.yes = true
	return sub
}

// devPullSub runs one shipped sub-verb with a writer pinned to machine mode and
// its stdout CAPTURED, so the wrapper reads the sub-verb's own structured
// document (its receipt on success, its {ok:false,error} envelope on failure)
// instead of re-deriving either. stderr is passed through untouched: per-blob
// failures and progress lines still reach the operator as they happen.
func devPullSub(parent *writer, g globals, args []string, run func(*writer, globals, []string) int) (int, []byte) {
	var buf bytes.Buffer
	sub := *parent
	sub.stdout = &buf
	sub.output = "json"
	sub.outputExplicit = true
	code := run(&sub, g, args)
	return code, buf.Bytes()
}

// devPullQuietWriter is a sub-writer for the blob halves: machine mode routes
// their summary line to stderr (progressf) so it never lands inside the single
// human receipt, while the report STRUCT comes back to the caller directly.
func devPullQuietWriter(parent *writer) *writer {
	sub := *parent
	sub.stdout = io.Discard
	sub.output = "json"
	sub.outputExplicit = true
	return &sub
}

// devPullSubWhy lifts the sub-verb's OWN error message out of its captured
// envelope. The wrapper must never invent a cause for a refusal it did not make;
// fallback is used only when the sub-verb printed nothing parseable.
func devPullSubWhy(doc []byte, fallback string) string {
	var env struct {
		Error struct {
			Message string `json:"message"`
			Code    string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(doc, &env); err == nil && strings.TrimSpace(env.Error.Message) != "" {
		if env.Error.Code != "" {
			return env.Error.Message + " [" + env.Error.Code + "]"
		}
		return env.Error.Message
	}
	return fallback
}

// devPullInt reads one integer out of a captured sub-verb payload, or -1 when
// the key is absent or not a number — never a fabricated zero.
func devPullInt(doc []byte, key string) int64 {
	var m map[string]any
	if err := json.Unmarshal(doc, &m); err != nil {
		return -1
	}
	if f, ok := m[key].(float64); ok {
		return int64(f)
	}
	return -1
}

// devPullBundlePath resolves where the bundle lives. An explicit --bundle is the
// operator's file and is never removed. The default is DETERMINISTIC — keyed on
// source + workspace + dataset under the temp dir — so the named re-run command
// resolves to the same artifact without the operator having to copy a random
// path out of an error message. ownDir reports whether this verb created the
// directory and may therefore clean it up.
func devPullBundlePath(explicit, sourceLabel, ws, ds string) (bundle string, ownDir bool) {
	if explicit != "" {
		return explicit, false
	}
	key := devPullSlug(sourceLabel) + "-" + devPullSlug(ws) + "-" + devPullSlug(ds)
	return filepath.Join(os.TempDir(), "bp-dev-pull", key, "bundle.tar"), true
}

// devPullSlug reduces a label to a filesystem-safe token so a server URL can key
// a directory name without ever escaping it.
func devPullSlug(s string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(s) {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		return "pull"
	}
	return out
}

// devPullRerunCmd renders the EXACT command that continues from a failure —
// the whole point of a named state is that the operator does not have to
// reconstruct it.
func devPullRerunCmd(src, tgt, ws, ds, bundle string, resume bool) string {
	cmd := fmt.Sprintf("bp dev pull %s %s %s/%s --yes --bundle %s", src, tgt, ws, ds, bundle)
	if resume {
		cmd += " --resume"
	}
	return cmd
}

// devPullSurviving names a bundle path only when a file is actually there. An
// export that died left the destination untouched, and naming an artifact that
// does not exist is the same lie as hiding one that does.
func devPullSurviving(bundle string) string {
	if fi, err := os.Stat(bundle); err == nil && !fi.IsDir() {
		return bundle
	}
	return ""
}

// devPullSurvivingDir is devPullSurviving for the sidecar directory.
func devPullSurvivingDir(dir string) string {
	if devPullHasSidecar(dir) {
		return dir
	}
	return ""
}

// devPullHasSidecar reports whether a sidecar directory exists. A pull whose
// dataset carries no media never creates one, and asking the upload half to walk
// a directory that was never made would turn "no blobs" into a named failure.
func devPullHasSidecar(dir string) bool {
	fi, err := os.Stat(dir)
	return err == nil && fi.IsDir()
}

// devPullEmptyAs renders an absent manifest field as <absent> rather than as an
// empty string that reads like a value.
func devPullEmptyAs(s string) string {
	if s == "" {
		return "<absent>"
	}
	return s
}

// devPullUnknownServer refuses a server name the saved config does not know, and
// names which END of the pull it was for — "no known server matches x" leaves an
// operator guessing which of the two positionals was wrong.
func devPullUnknownServer(out *writer, cfg *Config, q, side string) int {
	names := knownNames(cfg)
	if out.machineOut() {
		det, err := json.Marshal(map[string]any{"side": side, "known": names})
		if err == nil {
			return useErrorDetailed(out, "not_found",
				fmt.Sprintf("no known server matches %q (the %s of the pull)", q, side), exitUsage, det)
		}
	}
	useError(out, "not_found", fmt.Sprintf("no known server matches %q (the %s of the pull)", q, side), exitUsage)
	if len(names) > 0 {
		out.errf("known servers: %s", joinComma(names))
		out.errf("run `bp servers` for details.")
	} else {
		out.errf("no saved servers yet — run 'bp setup --target connect --server <url>'")
	}
	return exitUsage
}

// devPullNoToken refuses an end with no credential. The token comes from the
// SAVED ENTRY (or an explicit --token) and from nowhere else: falling back to an
// ambient environment variable is how a production admin token ends up aimed at
// the wrong box, which is the exact accident this verb exists to prevent.
func devPullNoToken(out *writer, name, side string) int {
	code := useError(out, "dev_pull_no_token",
		fmt.Sprintf("the %s server %q has no saved token — this verb reads credentials from the saved server entry only, never from the environment", side, name),
		exitAuth)
	if !out.machineOut() {
		out.errf("  save one with `bp setup --target connect --server %s`, or pass --token for both ends.", name)
	}
	return code
}

// ── help ─────────────────────────────────────────────────────────────────────

func printDevHelp(out *writer) {
	out.outf(`bp dev — the personal development server loop

usage:
  bp dev pull <source-server> <target-server> <workspace>/<dataset> --yes

commands:
  pull    pull a dev-scrubbed dataset (with its media) from one server into another

Run 'bp dev pull --help' for the pull's own flags.`)
}

func printDevPullHelp(out *writer) {
	out.outf(`bp dev pull — one edge-to-edge pull: export + grain check + blobs + merge import

usage:
  %s

Composes the shipped bundle verbs into one transaction. Both servers are
resolved from SAVED SERVER ENTRIES (like 'bp migrate'), and each end uses its
own entry's token — credentials are never read from the environment.

  1. export   GET the bundle at profile=%s, dataset grain, from the source
  2. verify   the bundle manifest must declare that profile and that dataset;
              a workspace-grain bundle is REFUSED before anything is imported
  3. blobs    fetch every media file the bundle names into <bundle>.blobs
  4. import   POST the bundle to the target with mode=merge (a re-run refreshes)
  5. blobs    PUT every sidecar file back, path-verbatim
  6. reconcile  the target must receive exactly as many blobs as the source served

arguments:
  <source-server>   saved server name, display name, or URL to pull FROM
  <target-server>   saved server name, display name, or URL to pull INTO
  <workspace>/<dataset>   the bundle grain (the route has no project grain)

flags:
  --yes             required: the import WRITES content and media into the target
  --bundle <path>   keep the bundle here instead of a temp directory (never removed)
  --keep            keep the temporary bundle and sidecar after a successful pull
  --resume          reuse the bundle and sidecar already on disk; skip steps 1-3
  --dry-run         print the five requests it would make and send nothing

Every failure names its phase, the artifacts that survive on disk, and the exact
command that resumes or safely restarts it. A pull whose media set is short is a
non-zero exit, never a receipt with a footnote.`, devPullUsage, devPullProfile)
}
