package cli

// scaffy_remote_cmd.go is the REMOTE half of `bp scaffy` — W4's
// commands-as-content surface (charter D48–D50). Two verbs plus the
// pulled-command consent gate:
//
//	bp scaffy ls --remote          the server's command catalog as a table
//	bp scaffy pull <concept>[/<variant>]
//	                               fetch ONE command document, validate it
//	                               locally BEFORE any write, then land the
//	                               byte-identical .scaffy + a committed
//	                               .provenance.json sidecar under
//	                               scaffy/commands/
//
// EVERY server-touching scaffy line lives HERE, never in scaffy_cmd.go:
// TestScaffyPureLocal substring-scans that file for the context/manifest
// helper names (the D31/D40 purity law), so scaffy_cmd.go only carries the
// dispatch cases. paper_cmd.go is the precedent for a built-in resolving
// resolveContext in its own file.
//
// Trust model (D49) — pull NEVER runs anything:
//
//  1. tokenless fetch over the generic query endpoint (zero new API, D50);
//  2. scaffy.ValidateFile on the fetched bytes BEFORE any disk write — any
//     finding is a loud refusal (exit 5) with NOTHING written;
//  3. the source lands byte-identical (no banner, no reformat — the sidecar's
//     source_sha256 must stay meaningful) next to a COMMITTED provenance
//     sidecar. The sidecar lives under scaffy/commands/ — NEVER under the
//     gitignored .scaffy/ (that is the receipts lifecycle, D35);
//  4. the command's ASSERT CMD templates print labeled UNSUBSTITUTED, with
//     the --dry-run preview hint;
//  5. at run time, a sidecar-marked file is consent-gated: the engine dry-run
//     enumerates the SUBSTITUTED would-run CMDs (TIER ci stays deferred, never
//     local), then the run needs --yes or an interactive TTY confirmation.
//     Non-TTY without --yes refuses (exit 2). Repo-authored files (no sidecar)
//     keep the W3 behavior exactly.
//
// No sandbox pretense — validate-first + enumerate + consent + provenance IS
// the model (D49).

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/mattn/go-isatty"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// scaffyCommandsDir is where pulled commands (and their provenance sidecars)
// land, relative to the cwd — the same repo-root resolution run/remove use.
const scaffyCommandsDir = "scaffy/commands"

// scaffyProvenanceVersion is the sidecar schema version (D49).
const scaffyProvenanceVersion = 1

// Provenance-drift rule IDs for `bp scaffy pull --check`. They EXTEND the
// R-00x repo/provenance family (scaffy.RuleRepo* is R-001..R-003) but live
// CLI-side, not in the pure engine package: drift detection re-fetches the
// served doc, and the engine (internal/scaffy) is network-free by law (D31).
// Two axes, one rule each — the repocheck precedent of one ID per condition:
//
//	R-004  the local .scaffy no longer matches the sidecar's source_sha256 —
//	       a hand-edit since pull (or the pulled file went missing);
//	R-005  the server's current command doc has drifted from the sidecar —
//	       its source bytes or _rev moved, or it is no longer served.
const (
	RuleProvenanceLocalEdit   = "R-004"
	RuleProvenanceServerDrift = "R-005"
)

// scaffyRemotePageLimit is the query page size — the server's max limit clamp
// (mirrors paperPageSize). BOTH remote callers drain the catalog with an offset
// loop — ls --remote (runScaffyLsRemote) and pull (scaffyFetchCommandDocs) — so
// a catalog past 1000 commands is fully paged, never truncated at one page.
const scaffyRemotePageLimit = 1000

// scaffyStdin is the consent prompt's input; scaffyStdinIsTTY reports whether
// it is an interactive terminal. Package vars (the hzStdin idiom) so tests can
// drive both the interactive and the non-TTY refusal paths deterministically.
var scaffyStdin io.Reader = os.Stdin

var scaffyStdinIsTTY = func(r io.Reader) bool {
	f, ok := r.(*os.File)
	return ok && isatty.IsTerminal(f.Fd())
}

// scaffyCommandDoc is one served command document: identity + the label-spine
// metadata (D45/D46) + the verbatim .scaffy source.
type scaffyCommandDoc struct {
	ID        string `json:"_id"`
	Rev       string `json:"_rev"`
	Title     string `json:"title"`
	Concept   string `json:"concept"`
	Variant   string `json:"variant"`
	Domain    string `json:"domain"`
	Direction string `json:"direction"`
	Source    string `json:"source"`
}

// scaffyProvenance is the committed sidecar (D49): where a pulled command came
// from and the sha256 of the exact bytes written next to it.
type scaffyProvenance struct {
	ProvenanceVersion int    `json:"provenance_version"`
	Server            string `json:"server"`
	DocID             string `json:"doc_id"`
	Rev               string `json:"rev,omitempty"`
	Concept           string `json:"concept"`
	Variant           string `json:"variant"`
	Domain            string `json:"domain"`
	Direction         string `json:"direction"`
	FetchedAt         string `json:"fetched_at"`
	SourceSHA256      string `json:"source_sha256"`
}

// runScaffyLs is `bp scaffy ls --remote` — the server catalog. A bare
// `bp scaffy ls` is a usage error today: the local corpus is a directory
// listing away, and D48 pins only the remote form.
func runScaffyLs(out *writer, g globals, args []string) int {
	remote := false
	for _, a := range args {
		switch {
		case a == "--remote":
			remote = true
		case strings.HasPrefix(a, "-") && a != "-":
			return usageErrf(out, func() { printScaffyLsHelp(out) }, "unknown ls flag %q", a)
		default:
			return usageErrf(out, func() { printScaffyLsHelp(out) }, "scaffy ls takes no positional arguments (got %q)", a)
		}
	}
	if !remote {
		return usageErrf(out, func() { printScaffyLsHelp(out) },
			"scaffy ls needs --remote (the local corpus is just `ls scaffy/commands/`)")
	}
	return runScaffyLsRemote(out, g)
}

// runScaffyLsRemote fetches the concept × variant × domain catalog over the
// generic query endpoint (D50 — zero new API; tokenless works when the schema
// is public) and renders it through the existing table machinery: the
// documents envelope is already special-cased in renderTable.
//
// It pages via an offset loop (mirroring scaffyFetchCommandDocs) so a catalog
// past scaffyRemotePageLimit commands drains fully — a single doRequest would
// silently truncate at the server's limit clamp. Pages accumulate as RAW
// json.RawMessage documents, NOT the typed scaffyCommandDoc: that struct has no
// Description field and would drop the table's description column. The pages are
// re-assembled into the {documents:[…]} envelope that renderTable and -o json
// (renderRaw) already expect.
func runScaffyLsRemote(out *writer, g globals) int {
	ctx := resolveContext(g)
	base := scaffyCommandQueryURL(ctx)
	headers := scaffyAuthHeaders(ctx)

	docs := make([]json.RawMessage, 0)
	offset := 0
	for {
		params := url.Values{}
		params.Set("fields", "title,concept,variant,domain,description")
		params.Set("order", "concept:asc")
		params.Set("limit", strconv.Itoa(scaffyRemotePageLimit))
		params.Set("offset", strconv.Itoa(offset))
		u := base + "?" + params.Encode()

		status, body, err := doRequest("GET", u, headers, nil)
		if err != nil {
			return useError(out, "network", "scaffy ls --remote: "+err.Error(), exitGeneric)
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, body)
			renderError(out, ae)
			return ae.exit
		}

		page := scaffyRawDocuments(unwrapResult(body))
		docs = append(docs, page...)
		if len(page) < scaffyRemotePageLimit {
			break
		}
		offset += scaffyRemotePageLimit
	}

	payload, err := json.Marshal(struct {
		Documents []json.RawMessage `json:"documents"`
	}{Documents: docs})
	if err != nil {
		return useError(out, "internal", "scaffy ls --remote: "+err.Error(), exitGeneric)
	}
	if out.machineOut() {
		out.renderRaw(payload)
	} else {
		renderTable(out, payload)
	}
	return exitOK
}

// scaffyRawDocuments pulls the documents array out of a query payload as raw
// bytes, tolerating both the unwrapped {documents:[…]} shape and a still-wrapped
// {result:{documents:[…]}} one. Raw messages preserve every served field (the
// description column especially) that the typed scaffyCommandDoc would drop.
func scaffyRawDocuments(payload []byte) []json.RawMessage {
	var env struct {
		Result struct {
			Documents []json.RawMessage `json:"documents"`
		} `json:"result"`
		Documents []json.RawMessage `json:"documents"`
	}
	if err := json.Unmarshal(payload, &env); err != nil {
		return nil
	}
	if env.Documents != nil {
		return env.Documents
	}
	return env.Result.Documents
}

// runScaffyPull is `bp scaffy pull <concept>[/<variant>]` — the D49 pipeline:
// fetch → validate BEFORE any write → byte-identical source + committed
// provenance sidecar → print the UNSUBSTITUTED ASSERT CMD templates and the
// dry-run preview hint. A concept matching several variants lists them and
// exits 2 (D48); pull itself never executes anything.
func runScaffyPull(out *writer, g globals, args []string) int {
	var positionals []string
	check := false
	for _, a := range args {
		switch {
		case a == "--check":
			check = true
		case strings.HasPrefix(a, "-") && a != "-":
			return usageErrf(out, func() { printScaffyPullHelp(out) }, "unknown pull flag %q", a)
		default:
			positionals = append(positionals, a)
		}
	}
	if check {
		if len(positionals) != 0 {
			return usageErrf(out, func() { printScaffyPullHelp(out) },
				"pull --check takes no target — it audits every pulled command under %s (got %q)",
				scaffyCommandsDir, strings.Join(positionals, " "))
		}
		return runScaffyPullCheck(out, g)
	}
	if len(positionals) != 1 {
		return usageErrf(out, func() { printScaffyPullHelp(out) },
			"pull needs exactly one <concept>[/<variant>] (got %d)", len(positionals))
	}
	concept, variant := positionals[0], ""
	if i := strings.Index(concept, "/"); i >= 0 {
		concept, variant = concept[:i], concept[i+1:]
		if concept == "" || variant == "" {
			return usageErrf(out, func() { printScaffyPullHelp(out) },
				"malformed target %q — expected <concept> or <concept>/<variant>", positionals[0])
		}
	}

	ctx := resolveContext(g)
	docs, err := scaffyFetchCommandDocs(ctx)
	if err != nil {
		return useError(out, "network", "scaffy pull: "+err.Error(), exitGeneric)
	}

	var matches []scaffyCommandDoc
	for _, d := range docs {
		if d.Concept != concept {
			continue
		}
		if variant != "" && d.Variant != variant {
			continue
		}
		matches = append(matches, d)
	}
	switch {
	case len(matches) == 0:
		msg := fmt.Sprintf("no command %q on %s", positionals[0], ctx.Server)
		if concepts := scaffyKnownConcepts(docs); len(concepts) > 0 {
			msg += " — known concepts: " + strings.Join(concepts, ", ")
		}
		return useError(out, "not_found", "scaffy pull: "+msg, exitNotFound)
	case len(matches) > 1:
		variants := make([]string, 0, len(matches))
		for _, m := range matches {
			variants = append(variants, concept+"/"+m.Variant)
		}
		sort.Strings(variants)
		return usageErrf(out, nil, "scaffy pull: concept %q has %d variants — pick one: %s",
			concept, len(matches), strings.Join(variants, ", "))
	}
	doc := matches[0]
	if doc.Source == "" {
		return useError(out, "invalid",
			fmt.Sprintf("scaffy pull: document %q carries no source — refusing, nothing written", doc.ID),
			exitValidation)
	}
	src := []byte(doc.Source)

	// Validate-first (D49): the W2 validator gates ANY fetched command before
	// a single byte lands. Any finding = loud refusal, exit 5, NOTHING written.
	displayName := doc.ID + ".scaffy"
	if findings := scaffy.ValidateFile(displayName, src); len(findings) > 0 {
		if out.machineOut() {
			out.emitStructured(map[string]any{
				"ok":       false,
				"doc_id":   doc.ID,
				"findings": scaffyFindingsJSON(findings),
			})
		} else {
			for _, f := range findings {
				out.outf("%s", f.String())
				if f.Hint != "" {
					out.outf("  hint: %s", f.Hint)
				}
			}
			out.userErr("scaffy pull: fetched command failed validation — nothing written")
		}
		return exitValidation
	}

	// Zero findings ⇒ Parse is clean; the AST supplies the ASSERT CMD templates
	// and backfills any metadata the served doc left blank (header is truth,
	// D46 derives the doc fields from it at seed time).
	cmd, _ := scaffy.Parse(displayName, src)
	meta := scaffyPullMeta(doc, cmd)
	meta.Server = ctx.Server
	id := fmt.Sprintf("%s--%s--%s", meta.Domain, meta.Concept, meta.Variant)

	destRel := filepath.Join(filepath.FromSlash(scaffyCommandsDir), id+".scaffy")
	sidecarRel := filepath.Join(filepath.FromSlash(scaffyCommandsDir), id+".provenance.json")

	// Path containment (security): id is built from RAW remote metadata —
	// meta.Domain/Concept/Variant are doc.Domain/… JSON fields with no charset
	// gate, and the pre-write ValidateFile above gates only doc.Source, never the
	// filename metadata. filepath.Join Cleans, so a domain like "../../../tmp/evil"
	// collapses the destination OUT of scaffy/commands/ (dest becomes
	// ../tmp/evil--…), and a '/'-bearing field plants a surprise subdirectory.
	// Refuse BEFORE any MkdirAll/WriteFile: reject the WHOLE id if it carries a
	// path separator or a ".." segment (all three fields flow into id, not just
	// Domain), and confirm both computed paths stay under the commands base. The
	// forward-slash "../" vector is the only one that escapes on non-Windows —
	// rejecting only a leading '/' or backslash would be incomplete.
	base := filepath.FromSlash(scaffyCommandsDir)
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") ||
		!scaffyPathWithinBase(base, destRel) || !scaffyPathWithinBase(base, sidecarRel) {
		return useError(out, "invalid",
			fmt.Sprintf("scaffy pull: document %q metadata yields an out-of-tree path — id %q must not contain '/', '\\' or '..' (domain/concept/variant are untrusted server fields); refusing, nothing written",
				doc.ID, id),
			exitValidation)
	}

	if err := os.MkdirAll(filepath.Dir(destRel), 0o755); err != nil {
		return useError(out, "io", "scaffy pull: "+err.Error(), exitNotFound)
	}
	// Byte-identical: the .scaffy file IS the truth — no banner, no reformat,
	// so source_sha256 stays meaningful against both the file and the server.
	if err := os.WriteFile(destRel, src, 0o644); err != nil {
		return useError(out, "io", "scaffy pull: "+err.Error(), exitNotFound)
	}
	sum := sha256.Sum256(src)
	meta.FetchedAt = time.Now().UTC().Format(time.RFC3339)
	meta.SourceSHA256 = hex.EncodeToString(sum[:])
	sidecarBytes, merr := json.MarshalIndent(meta, "", "  ")
	if merr != nil {
		return useError(out, "io", "scaffy pull: encode provenance: "+merr.Error(), exitNotFound)
	}
	if err := os.WriteFile(sidecarRel, append(sidecarBytes, '\n'), 0o644); err != nil {
		return useError(out, "io", "scaffy pull: "+err.Error(), exitNotFound)
	}

	cmdTemplates := scaffyAssertCmdTemplates(cmd)
	if out.machineOut() {
		out.emitStructured(map[string]any{
			"ok":            true,
			"doc_id":        meta.DocID,
			"rev":           meta.Rev,
			"server":        meta.Server,
			"concept":       meta.Concept,
			"variant":       meta.Variant,
			"domain":        meta.Domain,
			"direction":     meta.Direction,
			"path":          filepath.ToSlash(destRel),
			"provenance":    filepath.ToSlash(sidecarRel),
			"source_sha256": meta.SourceSHA256,
			"assert_cmds":   toGeneric(cmdTemplates),
		})
		return exitOK
	}

	out.outf("● pulled %s (doc %s rev %s from %s)", filepath.ToSlash(destRel), meta.DocID, orDash(meta.Rev), meta.Server)
	out.outf("● provenance %s", filepath.ToSlash(sidecarRel))
	if len(cmdTemplates) == 0 {
		out.outf("this command declares no ASSERT CMD lines — nothing will ever be executed by it")
	} else {
		out.outf("ASSERT CMD templates (UNSUBSTITUTED — {{.tokens}} resolve at run time):")
		for _, c := range cmdTemplates {
			line := "  " + c.Text
			if c.Tier == "ci" {
				line += "   [TIER ci — deferred to the PR, never runs locally]"
			}
			out.outf("%s", line)
		}
	}
	out.outf("preview the exact substituted lines: bp scaffy run %s --var K=V... --dry-run", filepath.ToSlash(destRel))
	out.outf("running it is consent-gated: the run enumerates the CMDs and asks first (or pass --yes)")
	return exitOK
}

// scaffyAssertCmdTemplate is one ASSERT CMD line as authored (unsubstituted).
type scaffyAssertCmdTemplate struct {
	Text string `json:"text"`
	Tier string `json:"tier,omitempty"`
}

// scaffyAssertCmdTemplates lists a command's ASSERT CMD lines verbatim.
func scaffyAssertCmdTemplates(cmd *scaffy.Command) []scaffyAssertCmdTemplate {
	if cmd == nil {
		return nil
	}
	var out []scaffyAssertCmdTemplate
	for _, a := range cmd.Asserts {
		if a.Kind == scaffy.AssertCmd {
			out = append(out, scaffyAssertCmdTemplate{Text: a.Text, Tier: a.Tier})
		}
	}
	return out
}

// scaffyPullMeta merges the served doc's metadata with the parsed header —
// the doc fields win (they are what the catalog serves), the header backfills
// blanks so a sparsely-seeded doc still yields an honest sidecar + file id.
func scaffyPullMeta(doc scaffyCommandDoc, cmd *scaffy.Command) *scaffyProvenance {
	meta := &scaffyProvenance{
		ProvenanceVersion: scaffyProvenanceVersion,
		DocID:             doc.ID,
		Rev:               doc.Rev,
		Concept:           doc.Concept,
		Variant:           doc.Variant,
		Domain:            doc.Domain,
		Direction:         doc.Direction,
	}
	if cmd != nil {
		if meta.Concept == "" && cmd.Header.Concept != nil {
			meta.Concept = cmd.Header.Concept.Value
		}
		if meta.Variant == "" && cmd.Header.Variant != nil {
			meta.Variant = cmd.Header.Variant.Value
		}
		if meta.Domain == "" && cmd.Header.Domain != nil {
			meta.Domain = cmd.Header.Domain.Value
		}
		if meta.Direction == "" {
			meta.Direction = cmd.Direction()
		}
	}
	return meta
}

// scaffyPathWithinBase reports whether target stays inside base after cleaning —
// false when target IS base's parent ("..") or reaches outside it ("../…"), and
// false when filepath.Rel cannot even express target relative to base (a
// leading-".." target base cannot reach lexically). This is the authoritative
// path-containment gate for a pull destination whose id is derived from raw
// remote metadata; it fails closed on any ambiguity.
func scaffyPathWithinBase(base, target string) bool {
	rel, err := filepath.Rel(filepath.Clean(base), filepath.Clean(target))
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// scaffyKnownConcepts lists the distinct concepts the server carries, sorted,
// for the not-found hint.
func scaffyKnownConcepts(docs []scaffyCommandDoc) []string {
	seen := map[string]bool{}
	var out []string
	for _, d := range docs {
		if d.Concept != "" && !seen[d.Concept] {
			seen[d.Concept] = true
			out = append(out, d.Concept)
		}
	}
	sort.Strings(out)
	return out
}

// scaffyCommandQueryURL is the generic query endpoint for the command type —
// the flat /v1 route (D50: zero new API; the server's default-tenancy
// resolution scopes it, same as the deploy smoke test's query).
func scaffyCommandQueryURL(ctx manifest.Context) string {
	return strings.TrimRight(ctx.Server, "/") + "/v1/data/query/" + url.PathEscape(ctx.Dataset) + "/command"
}

// scaffyAuthHeaders carries the resolved bearer when one exists. Tokenless is
// the expected steady state — the command schema is public (D44) — but a
// configured token must not be dropped (private mirrors, dev servers).
func scaffyAuthHeaders(ctx manifest.Context) map[string]string {
	headers := map[string]string{}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}
	return headers
}

// scaffyFetchCommandDocs drains the server's command documents (full docs —
// pull needs source + metadata + rev), paging like paperFetchAll so a >1000
// catalog still resolves.
func scaffyFetchCommandDocs(ctx manifest.Context) ([]scaffyCommandDoc, error) {
	base := scaffyCommandQueryURL(ctx)
	headers := scaffyAuthHeaders(ctx)
	var out []scaffyCommandDoc
	offset := 0
	for {
		params := url.Values{}
		params.Set("limit", strconv.Itoa(scaffyRemotePageLimit))
		params.Set("offset", strconv.Itoa(offset))
		u := base + "?" + params.Encode()

		status, body, err := doRequest("GET", u, headers, nil)
		if err != nil {
			return nil, err
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, body)
			return nil, fmt.Errorf("status %d: %s", status, ae.errorMessage())
		}

		var env struct {
			Result struct {
				Documents []json.RawMessage `json:"documents"`
			} `json:"result"`
			Documents []json.RawMessage `json:"documents"`
		}
		if jerr := json.Unmarshal(body, &env); jerr != nil {
			return nil, fmt.Errorf("parse query response: %w", jerr)
		}
		rawDocs := env.Result.Documents
		if rawDocs == nil {
			rawDocs = env.Documents
		}
		for _, r := range rawDocs {
			var d scaffyCommandDoc
			if jerr := json.Unmarshal(r, &d); jerr != nil {
				return nil, fmt.Errorf("parse command document: %w", jerr)
			}
			out = append(out, d)
		}
		if len(rawDocs) < scaffyRemotePageLimit {
			break
		}
		offset += scaffyRemotePageLimit
	}
	return out, nil
}

// ---- pulled-command consent gate (D49) -------------------------------------

// scaffyProvenanceSidecar is the sidecar path adjacent to a .scaffy file —
// presence of this file marks the command as PULLED and consent-gates its run.
func scaffyProvenanceSidecar(path string) string {
	return strings.TrimSuffix(path, ".scaffy") + ".provenance.json"
}

// scaffyIsPulled reports whether path carries an adjacent provenance sidecar.
func scaffyIsPulled(path string) bool {
	info, err := os.Stat(scaffyProvenanceSidecar(path))
	return err == nil && !info.IsDir()
}

// scaffyRunConsent gates a REAL run of a pulled command (D49). It first runs
// the engine dry (RunReport.Asserts carries the SUBSTITUTED shell text with
// would-run vs deferred), prints the would-run CMDs and the deferred TIER ci
// ones separately — honestly saying "no local commands run" when every CMD is
// deferred — then requires --yes or an interactive TTY confirmation.
//
// Returns (true, 0) to proceed. A dry-run aborting at an op (anchor mismatch,
// var-contract violation) refuses with THAT error — no CMD list is implied
// for a command that cannot even apply. Non-TTY without --yes refuses exit 2.
func scaffyRunConsent(out *writer, g globals, path string, vars map[string]string, root string) (bool, int) {
	dry, err := scaffy.Run(scaffy.RunOptions{CommandPath: path, Vars: vars, DryRun: true, RepoRoot: root})
	if err != nil {
		return false, scaffyEngineError(out, "run", err, func() { printScaffyRunHelp(out) })
	}

	var wouldRun, deferred []string
	for _, a := range dry.Asserts {
		if a.Kind != "cmd" {
			continue
		}
		switch a.Status {
		case scaffy.AssertWouldRun:
			wouldRun = append(wouldRun, a.Text)
		case scaffy.AssertDeferred:
			deferred = append(deferred, a.Text)
		}
	}

	// Machine output (-o json|yaml) is non-interactive by definition: never
	// prompt, never interleave prose with the run's structured envelope. With
	// --yes the gate passes silently (the run emits the one envelope); without
	// it the refusal IS an envelope, carrying the same CMD enumeration the
	// human path prints — usageErrf's machine-parity convention.
	if out.machineOut() {
		if g.yes {
			return true, 0
		}
		out.emitStructured(map[string]any{
			"ok": false,
			"error": map[string]any{
				"code":    "consent_required",
				"message": "refusing to run a pulled command without --yes (consent gate, D49)",
			},
			"would_run_cmds": wouldRun,
			"deferred_cmds":  deferred,
		})
		return false, exitUsage
	}

	out.outf("pulled command (provenance sidecar present) — consent gate:")
	if len(wouldRun) == 0 {
		if len(deferred) > 0 {
			out.outf("no local commands run — all %d CMD(s) are TIER ci, deferred to CI", len(deferred))
		} else {
			out.outf("no local commands run — this command declares no ASSERT CMD lines")
		}
	} else {
		out.outf("would run %d local CMD(s) (substituted):", len(wouldRun))
		for _, c := range wouldRun {
			out.outf("  $ %s", c)
		}
	}
	if len(wouldRun) > 0 && len(deferred) > 0 {
		out.outf("%d CMD(s) deferred to CI, never run locally:", len(deferred))
		for _, c := range deferred {
			out.outf("  … %s", c)
		}
	}

	if g.yes {
		return true, 0
	}
	if scaffyStdinIsTTY(scaffyStdin) {
		fmt.Fprintf(out.stderr, "run this pulled command? [y/N] ")
		line, rerr := bufio.NewReader(scaffyStdin).ReadString('\n')
		if rerr != nil && line == "" {
			out.userErr("scaffy run: aborted — could not read confirmation: %v", rerr)
			return false, exitUsage
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "y", "yes":
			return true, 0
		}
		out.userErr("scaffy run: aborted — pulled command not run (pass --yes to skip the prompt)")
		return false, exitUsage
	}
	out.userErr("scaffy run: refusing to run a pulled command without --yes (stdin is not a TTY — consent gate, D49)")
	return false, exitUsage
}

// ---- pull --check: provenance drift detection (D49 follow-up) --------------

// runScaffyPullCheck audits every pulled command under scaffy/commands/ for
// drift against its committed provenance sidecar, on BOTH axes:
//
//	R-004 local hand-edit  — sha256(local .scaffy) ≠ sidecar.source_sha256
//	                         (or the .scaffy went missing since it was pulled);
//	R-005 server-side drift — the command's OWN source server (prov.Server,
//	                         NOT the connected one) no longer matches the
//	                         sidecar's recorded source_sha256 / rev, the doc is
//	                         gone from that server's catalog, the sidecar records
//	                         no server, or that server is unreachable (D104).
//
// Any mismatch is a loud NAMED finding in the compiler "file:line: RULE msg"
// house style (scaffy.Finding.String), exit 5 — never silent (D34). A clean
// audit prints a one-line summary of what was verified and exits 0. Honors
// -o json like its siblings: {ok, checked, findings}.
func runScaffyPullCheck(out *writer, g globals) int {
	dir := filepath.FromSlash(scaffyCommandsDir)
	pulled, err := scaffyPulledSidecars(dir)
	if err != nil {
		return useError(out, "io", "scaffy pull --check: "+err.Error(), exitNotFound)
	}
	if len(pulled) == 0 {
		if out.machineOut() {
			out.emitStructured(map[string]any{"ok": true, "checked": 0, "findings": []any{}})
			return exitOK
		}
		out.outf("clean: no pulled commands under %s to check", scaffyCommandsDir)
		return exitOK
	}

	// Axis (b) checks each pulled command against the server it was PULLED FROM
	// (its sidecar's prov.Server) — NOT whatever server bp happens to be pointed
	// at right now (D104). Sidecars are grouped by their source server so each
	// distinct catalog is fetched at most once; a fetch failure, or an empty /
	// absent prov.Server, is a NAMED finding on that command — never a silent
	// skip and never a false verdict against the wrong server's catalog.
	ctx := resolveContext(g)
	fetchCatalog := scaffyCatalogFetcher(ctx)

	var findings []scaffy.Finding
	for _, p := range pulled {
		findings = append(findings, scaffyCheckOne(p, fetchCatalog)...)
	}
	sort.Slice(findings, func(i, j int) bool {
		if findings[i].File != findings[j].File {
			return findings[i].File < findings[j].File
		}
		return findings[i].Rule < findings[j].Rule
	})

	if out.machineOut() {
		out.emitStructured(map[string]any{
			"ok":       len(findings) == 0,
			"checked":  len(pulled),
			"findings": scaffyFindingsJSON(findings),
		})
		if len(findings) > 0 {
			return exitValidation
		}
		return exitOK
	}

	for _, f := range findings {
		out.outf("%s", f.String())
		if f.Hint != "" {
			out.outf("  hint: %s", f.Hint)
		}
	}
	if len(findings) == 0 {
		out.outf("clean: %d pulled command(s) match their provenance (local sha + each command's own source server's rev/sha)",
			len(pulled))
		return exitOK
	}
	out.outf("%d drift finding(s) across %d pulled command(s) — re-pull to refresh, or revert the local edit",
		len(findings), len(pulled))
	return exitValidation
}

// scaffyPulledCommand pairs a provenance sidecar with the source file it
// vouches for.
type scaffyPulledCommand struct {
	SourcePath  string // scaffy/commands/<id>.scaffy
	SidecarPath string // scaffy/commands/<id>.provenance.json
}

// scaffyPulledSidecars lists the pulled commands under dir — one per committed
// *.provenance.json — sorted for deterministic reporting. A missing dir is not
// an error (nothing pulled yet); it yields an empty slice.
func scaffyPulledSidecars(dir string) ([]scaffyPulledCommand, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []scaffyPulledCommand
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".provenance.json") {
			continue
		}
		sidecar := filepath.Join(dir, e.Name())
		source := strings.TrimSuffix(sidecar, ".provenance.json") + ".scaffy"
		out = append(out, scaffyPulledCommand{SourcePath: source, SidecarPath: sidecar})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SidecarPath < out[j].SidecarPath })
	return out, nil
}

// scaffyCatalogFetcher returns a memoized per-server catalog resolver: it fetches
// each distinct provenance server's command catalog at most once and caches the
// {docID → doc} index (or the fetch error) so a tree with N sidecars spread across
// M servers costs M fetches, not N. The connected context's bearer is sent ONLY to
// the connected server — a FOREIGN provenance server is queried tokenless (the
// command schema is public, D44), never with the wrong server's credential.
func scaffyCatalogFetcher(ctx manifest.Context) func(server string) (map[string]scaffyCommandDoc, error) {
	type result struct {
		byID map[string]scaffyCommandDoc
		err  error
	}
	cache := map[string]*result{}
	return func(server string) (map[string]scaffyCommandDoc, error) {
		if r, ok := cache[server]; ok {
			return r.byID, r.err
		}
		sctx := ctx
		sctx.Server = server
		if server != ctx.Server {
			sctx.Token = ""
		}
		docs, err := scaffyFetchCommandDocs(sctx)
		r := &result{err: err}
		if err == nil {
			r.byID = make(map[string]scaffyCommandDoc, len(docs))
			for _, d := range docs {
				r.byID[d.ID] = d
			}
		}
		cache[server] = r
		return r.byID, r.err
	}
}

// scaffyCheckOne audits one pulled command on both drift axes. Findings point
// at the .scaffy source (the artifact a user reasons about) at its header line.
// A sidecar that won't even parse is itself R-004 drift — the provenance is
// unreadable, so nothing can be vouched for. Axis (b) is checked against the
// command's OWN source server (its sidecar's prov.Server), resolved through
// fetchCatalog — the wrong-server catalog is never consulted (D104): an empty
// prov.Server or an unreachable source server is its own NAMED R-005 finding,
// not a false verdict borrowed from whatever server bp is pointed at now.
func scaffyCheckOne(p scaffyPulledCommand, fetchCatalog func(server string) (map[string]scaffyCommandDoc, error)) []scaffy.Finding {
	rel := filepath.ToSlash(p.SourcePath)
	raw, err := os.ReadFile(p.SidecarPath)
	if err != nil {
		return []scaffy.Finding{{File: rel, Line: 1, Rule: RuleProvenanceLocalEdit,
			Msg: fmt.Sprintf("provenance sidecar unreadable (%s): %v", filepath.ToSlash(p.SidecarPath), err)}}
	}
	var prov scaffyProvenance
	if jerr := json.Unmarshal(raw, &prov); jerr != nil {
		return []scaffy.Finding{{File: rel, Line: 1, Rule: RuleProvenanceLocalEdit,
			Msg: fmt.Sprintf("provenance sidecar is not valid JSON (%s): %v", filepath.ToSlash(p.SidecarPath), jerr)}}
	}

	var findings []scaffy.Finding

	// Axis (a): local hand-edit. sha256 of the on-disk bytes vs the recorded one.
	src, serr := os.ReadFile(p.SourcePath)
	switch {
	case serr != nil:
		findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceLocalEdit,
			Msg:  fmt.Sprintf("pulled source is missing (%v) — the sidecar records it as pulled from %s", serr, orDash(prov.Server)),
			Hint: "re-pull the command, or delete the orphaned sidecar"})
	default:
		sum := sha256.Sum256(src)
		local := hex.EncodeToString(sum[:])
		if prov.SourceSHA256 != "" && local != prov.SourceSHA256 {
			findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceLocalEdit,
				Msg:  fmt.Sprintf("local edit since pull: sha256 %s ≠ recorded %s", scaffyShort(local), scaffyShort(prov.SourceSHA256)),
				Hint: "revert the file, or re-pull to accept the change"})
		}
	}

	// Axis (b): server-side drift, verified against the sidecar's OWN source
	// server (prov.Server) — never the currently-connected one (D104). An empty
	// server field or an unreachable server is a distinct NAMED finding, so the
	// audit stays honest rather than borrowing a verdict from the wrong catalog.
	switch {
	case prov.Server == "":
		findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceServerDrift,
			Msg:  "provenance sidecar records no source server — server-side drift cannot be verified",
			Hint: "re-pull the command so the sidecar records the server it came from"})
	default:
		byID, ferr := fetchCatalog(prov.Server)
		switch {
		case ferr != nil:
			findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceServerDrift,
				Msg:  fmt.Sprintf("provenance server %s unreachable (%v) — server-side drift unverified", prov.Server, ferr),
				Hint: "restore connectivity to the source server, or re-pull from a reachable mirror"})
		default:
			doc, ok := byID[prov.DocID]
			switch {
			case !ok:
				findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceServerDrift,
					Msg:  fmt.Sprintf("command doc %q no longer served by %s", prov.DocID, prov.Server),
					Hint: "the upstream command was removed or renamed — verify before relying on it"})
			default:
				srvSum := sha256.Sum256([]byte(doc.Source))
				srvSHA := hex.EncodeToString(srvSum[:])
				switch {
				case prov.SourceSHA256 != "" && srvSHA != prov.SourceSHA256:
					findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceServerDrift,
						Msg: fmt.Sprintf("server source changed: doc %s now sha256 %s ≠ recorded %s (rev %s → %s)",
							prov.DocID, scaffyShort(srvSHA), scaffyShort(prov.SourceSHA256), orDash(prov.Rev), orDash(doc.Rev)),
						Hint: "re-pull to adopt the server's current source"})
				case prov.Rev != "" && doc.Rev != "" && doc.Rev != prov.Rev:
					// Bytes identical, only the rev advanced (a metadata-only edit).
					findings = append(findings, scaffy.Finding{File: rel, Line: 1, Rule: RuleProvenanceServerDrift,
						Msg: fmt.Sprintf("server rev advanced %s → %s for doc %s (source bytes unchanged)",
							prov.Rev, doc.Rev, prov.DocID),
						Hint: "re-pull to refresh the sidecar rev"})
				}
			}
		}
	}
	return findings
}

// scaffyShort trims a hex digest to its first 12 chars for readable findings —
// enough to disambiguate, the full value lives in the sidecar.
func scaffyShort(sha string) string {
	if len(sha) <= 12 {
		return sha
	}
	return sha[:12] + "…"
}

func printScaffyPullHelp(out *writer) {
	out.outf(`usage: bp scaffy pull <concept>[/<variant>]
       bp scaffy pull --check

Fetch ONE command document from the connected server and land it locally —
never executing anything. The pipeline (D49):

  1. fetch the command catalog over the generic query endpoint (tokenless
     works — the command schema is public);
  2. validate the fetched source locally BEFORE any write: any finding is a
     loud refusal (exit 5) and NOTHING lands on disk;
  3. write the source BYTE-IDENTICAL to scaffy/commands/<domain>--<concept>--
     <variant>.scaffy (no banner, no reformat) plus a COMMITTED provenance
     sidecar <same>.provenance.json recording server, doc id, rev, metadata
     and the source sha256;
  4. print the command's ASSERT CMD templates (UNSUBSTITUTED) and the
     --dry-run preview hint.

A concept matching several variants lists them and exits 2 — pull
<concept>/<variant> to disambiguate. Running a pulled command is consent-
gated: bp scaffy run enumerates the substituted CMDs first and requires
--yes or an interactive confirmation.

--check audits every pulled command under scaffy/commands/ for drift against
its provenance sidecar, on both axes — a loud named finding per mismatch
(file:line: RULE msg), exit 5; a clean audit is a one-line summary, exit 0:

  R-004  local hand-edit: sha256(local .scaffy) no longer matches the
         sidecar's source_sha256 (or the source file went missing);
  R-005  server drift: the server's current doc source/rev has moved from the
         sidecar's recorded values, or the doc is no longer served.

-o json|-o yaml emits {ok, doc_id, rev, server, concept, variant, domain,
direction, path, provenance, source_sha256, assert_cmds} on a pull, or
{ok, checked, findings} on --check.

examples:
  bp scaffy pull oban-worker
  bp scaffy pull docs-card/add
  bp scaffy pull note -s https://guerrilla.barkpark.cloud
  bp scaffy pull --check

exit codes:
  0  pulled — source + sidecar written; or --check found no drift
  2  usage error, or an ambiguous concept (variants listed)
  4  no such concept/variant on the server, or an unwritable destination
  5  fetched source failed validation (nothing written); or --check found drift`)
}

func printScaffyLsHelp(out *writer) {
	out.outf(`usage: bp scaffy ls --remote

List the connected server's command catalog — one row per command document
(concept, variant, domain, title, description), ordered by concept. Zero new
API: this is the generic query endpoint, tokenless when the schema is public.

flags:
  --remote   required — the local corpus needs no verb (ls scaffy/commands/)

-o json|-o yaml emits the raw documents payload.

examples:
  bp scaffy ls --remote
  bp scaffy ls --remote -o json | jq '.documents[].concept'

exit codes:
  0  catalog rendered (possibly empty)
  2  usage error (missing --remote)
  1  network failure; server errors map per the standard exit table`)
}
