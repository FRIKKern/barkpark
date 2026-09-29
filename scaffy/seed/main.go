// Command seed derives one Barkpark `command` document payload per
// scaffy/commands/*.scaffy corpus file (scaffy epic, W4 slice 4; charter
// D46/D47).
//
// It is a payload EMITTER, not an uploader: the seed loop itself is two bp
// verbs per payload (create-or-replace + publish) documented in README.md
// alongside this file. Payloads are derived artifacts — the .scaffy files
// are the truth — so the out dir is never committed.
//
// Per file it:
//  1. scaffy.ValidateFile — ANY finding refuses the whole run (exit 1);
//     nothing invalid is ever seeded.
//  2. Derives the flat document fields:
//     _id         <domain>--<concept>--<variant>   (D46: concept alone is
//     NON-unique — add-docs-card and remove-docs-card
//     share concept "docs-card")
//     title       COMMAND header value
//     description DESCRIPTION header value
//     concept / variant / domain / direction  from the header
//     tags        TAGS list re-split into weighted entries with DISTINCT
//     descending strengths 90, 80, 70, … (publish-wall law:
//     strengths must be distinct; rationale is honest — it
//     derives from header order, nothing deeper)
//     source      the RAW FILE BYTES verbatim, never trimmed or decomposed
//  3. Writes <out>/<_id>.json and prints an audit line with the sha256 of
//     source, so the post-seed parity check (server sha256 == repo sha256)
//     has a local anchor.
//
// Usage:
//
//	go run ./scaffy/seed [--commands scaffy/commands] [--out scaffy/seed/out]
//	go run ./scaffy/seed --check [--commands scaffy/commands]
//
// --check is the drift tripwire (README §"Re-seed after amend"): it derives
// every payload in memory (NO out/ writes), fetches the served catalog
// tokenless, compares EVERY field seeding writes — title, description,
// concept, variant, domain, direction, tags and source — per command id,
// prints a table naming the divergent fields, and exits nonzero on ANY
// non-MATCH. A command file edited without a re-seed is one drift class this
// catches; a change under internal/scaffy/ that alters what the SAME bytes
// derive to, leaving source identical while title/direction/tags move, is the
// other, and comparing source alone was blind to it. It fails LOUD on any network error —
// a check that cannot check must never exit 0.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// defaultServer is the served catalog host when no config.json server field
// is present. --check reads the PUBLISHED perspective tokenless, so no
// credential is ever needed for the audit.
const defaultServer = "https://guerrilla.barkpark.cloud"

// defaultCommandsDir and corpusGlobPattern are THE corpus read set, in one
// place. deriveAll globs exactly `defaultCommandsDir/corpusGlobPattern`, the
// --commands flag defaults to it, and --impact's read-path predicate reads
// these same two identifiers rather than restating them — so a corpus move is
// one edit, not an enumeration to keep in step (an enumeration is a snapshot;
// this is the rule).
const (
	defaultCommandsDir = "scaffy/commands"
	corpusGlobPattern  = "*.scaffy"
)

// payload is one flat `command` document body for
// `bp doc create-or-replace command --file <payload>` — the CLI wraps it
// under a createOrReplace mutation; the type comes from the verb argument.
type payload struct {
	ID          string        `json:"_id"`
	Title       string        `json:"title"`
	Description string        `json:"description"`
	Concept     string        `json:"concept"`
	Variant     string        `json:"variant"`
	Domain      string        `json:"domain"`
	Direction   string        `json:"direction"`
	Tags        []weightedTag `json:"tags"`
	Source      string        `json:"source"`

	// File is the source .scaffy path this payload derived from. It is NOT
	// part of the document body (json:"-") — only used for audit lines and
	// the --check drift table.
	File string `json:"-"`
}

// weightedTag is one entry of the weighted-tags composite the publish wall
// (E3 tag-registry gate) validates: every tag name must resolve to a
// PUBLISHED type:tag doc, and strengths must be distinct.
type weightedTag struct {
	Tag       string `json:"tag"`
	Strength  int    `json:"strength"`
	Rationale string `json:"rationale"`
}

func main() {
	commandsDir := flag.String("commands", defaultCommandsDir, "directory of .scaffy corpus files")
	outDir := flag.String("out", "scaffy/seed/out", "directory to write one <_id>.json payload per command (derived; never committed)")
	check := flag.Bool("check", false, "audit mode: derive in memory (no out/ writes), fetch the served catalog tokenless, compare every field seeding writes (title, description, concept, variant, domain, direction, tags, source) per command id, print a table naming the divergent fields, exit nonzero on any drift")
	impact := flag.Bool("impact", false, "PR-time preflight: read a changed-file list, decide whether it touches what the DERIVER reads, and if so name the commands merging it would put behind the served catalog. Exit 0 = nothing to say, 2 = CANNOT READ, 3 = notice. See impact.go.")
	changedFiles := flag.String("changed-files", "-", "--impact only: file holding the PR's changed paths, one repo-relative path per line ('-' = stdin). Produce it with `git diff --name-only <merge-base>...<head>`.")
	root := flag.String("root", ".", "--impact only: module root the changed paths are relative to")
	flag.Parse()

	if *impact {
		os.Exit(runImpact(os.Stdout, os.Stderr, *root, *commandsDir, *changedFiles))
	}

	if *check {
		if err := runCheck(*commandsDir); err != nil {
			fmt.Fprintf(os.Stderr, "seed --check: %v\n", err)
			os.Exit(1)
		}
		return
	}

	if err := run(*commandsDir, *outDir); err != nil {
		fmt.Fprintf(os.Stderr, "seed: %v\n", err)
		os.Exit(1)
	}
}

func run(commandsDir, outDir string) error {
	payloads, err := deriveAll(commandsDir)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}

	for _, p := range payloads {
		out := filepath.Join(outDir, p.ID+".json")
		body, err := json.MarshalIndent(p, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(out, append(body, '\n'), 0o644); err != nil {
			return err
		}
		fmt.Printf("ok  %-42s tags=%d  sha256(source)=%x  <- %s\n",
			p.ID, len(p.Tags), sha256.Sum256([]byte(p.Source)), p.File)
	}
	fmt.Printf("emitted %d payloads to %s\n", len(payloads), outDir)
	return nil
}

// deriveAll runs the whole-corpus pipeline both `run` (emit) and `runCheck`
// (audit) share: glob → validate the ENTIRE corpus (a single finding anywhere
// refuses the run, so no partial/inconsistent set is ever produced) → derive →
// D46 uniqueness dedup. Payloads come back in sorted-filename order.
func deriveAll(commandsDir string) ([]*payload, error) {
	files, err := filepath.Glob(filepath.Join(commandsDir, corpusGlobPattern))
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("no .scaffy files under %s", commandsDir)
	}
	sort.Strings(files)

	invalid := false
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		if findings := scaffy.ValidateFile(f, src); len(findings) > 0 {
			invalid = true
			for _, fd := range findings {
				fmt.Fprintf(os.Stderr, "%s\n", fd)
			}
		}
	}
	if invalid {
		return nil, fmt.Errorf("validation findings — refusing to seed")
	}

	seen := map[string]string{} // _id -> source file (D46 uniqueness tripwire)
	payloads := make([]*payload, 0, len(files))
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		p, err := derive(f, src)
		if err != nil {
			return nil, err
		}
		if prev, dup := seen[p.ID]; dup {
			return nil, fmt.Errorf("%s: derived _id %q collides with %s — D46 ids must be unique", f, p.ID, prev)
		}
		seen[p.ID] = f
		payloads = append(payloads, p)
	}
	return payloads, nil
}

// derive maps one validated .scaffy source to its document payload. Every
// header field the document model needs must be present — a hole is an
// error, never a silently-empty field.
func derive(file string, src []byte) (*payload, error) {
	cmd, findings := scaffy.Parse(file, src)
	if len(findings) > 0 {
		// Unreachable after ValidateFile, but fail closed anyway.
		return nil, fmt.Errorf("%s: parse findings after validation: %s", file, findings[0])
	}

	get := func(name string, hf interface{ value() (string, bool) }) (string, error) {
		v, ok := hf.value()
		if !ok || strings.TrimSpace(v) == "" {
			return "", fmt.Errorf("%s: header %s is missing or empty", file, name)
		}
		return strings.TrimSpace(v), nil
	}

	h := cmd.Header
	title, err := get("COMMAND", opt{h.Command})
	if err != nil {
		return nil, err
	}
	description, err := get("DESCRIPTION", opt{h.Description})
	if err != nil {
		return nil, err
	}
	domain, err := get("DOMAIN", opt{h.Domain})
	if err != nil {
		return nil, err
	}
	concept, err := get("CONCEPT", opt{h.Concept})
	if err != nil {
		return nil, err
	}
	variant, err := get("VARIANT", opt{h.Variant})
	if err != nil {
		return nil, err
	}
	tagsRaw, err := get("TAGS", opt{h.Tags})
	if err != nil {
		return nil, err
	}
	direction := cmd.Direction()
	if direction == "" {
		return nil, fmt.Errorf("%s: DIRECTION is missing or invalid", file)
	}

	tags, err := weightedTags(file, tagsRaw)
	if err != nil {
		return nil, err
	}

	return &payload{
		ID:          domain + "--" + concept + "--" + variant,
		Title:       title,
		Description: description,
		Concept:     concept,
		Variant:     variant,
		Domain:      domain,
		Direction:   direction,
		Tags:        tags,
		Source:      string(src),
		File:        file,
	}, nil
}

// opt adapts a *scaffy.HeaderField to the small presence interface derive
// uses, so missing headers (nil) read uniformly.
type opt struct{ f *scaffy.HeaderField }

func (o opt) value() (string, bool) {
	if o.f == nil {
		return "", false
	}
	return o.f.Value, true
}

// weightedTags re-splits the parsed TAGS value (the parser joins the quoted
// list with ", ") into the weighted composite: distinct descending strengths
// from 90 in steps of 10 (90, 80, 70, …), honest positional rationales.
func weightedTags(file, raw string) ([]weightedTag, error) {
	parts := strings.Split(raw, ",")
	out := make([]weightedTag, 0, len(parts))
	seen := map[string]bool{}
	for i, p := range parts {
		name := strings.TrimSpace(p)
		if name == "" {
			return nil, fmt.Errorf("%s: TAGS entry %d is empty", file, i+1)
		}
		if seen[name] {
			return nil, fmt.Errorf("%s: TAGS entry %q repeats — weighted strengths must be distinct per tag", file, name)
		}
		seen[name] = true
		strength := 90 - 10*i
		if strength <= 0 {
			return nil, fmt.Errorf("%s: more than 9 TAGS entries — descending 90,80,… strengths exhausted", file)
		}
		out = append(out, weightedTag{
			Tag:       name,
			Strength:  strength,
			Rationale: fmt.Sprintf("TAGS position %d in the .scaffy header; strength mirrors header order.", i+1),
		})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: TAGS produced no entries", file)
	}
	return out, nil
}

// runCheck is the drift tripwire. It derives every payload in memory (no out/
// writes), fetches the served catalog tokenless, compares EVERY field seeding
// writes per command id — title, description, concept, variant, domain,
// direction, tags and source — prints a table naming the divergent fields, and
// returns a non-nil error (→ exit 1) on ANY non-MATCH. Network failures also return an error: a check that cannot check
// must never report clean.
func runCheck(commandsDir string) error {
	payloads, err := deriveAll(commandsDir)
	if err != nil {
		return err
	}

	server := serverURL()
	served, err := fetchServed(server)
	if err != nil {
		// Fail LOUD — an unreachable catalog is not "no drift".
		return fmt.Errorf("fetch served catalog from %s: %w", server, err)
	}

	drifted := printCheckTable(os.Stdout, server, payloads, served)
	if drifted > 0 {
		return fmt.Errorf("%d command(s) diverged from the served catalog — see the DIVERGENT FIELDS column and the breakdown above for whether to re-seed or to look at the deriver", drifted)
	}
	return nil
}

// servedDoc is one document as the served catalog returns it. It mirrors
// `payload`'s nine seeded fields EXACTLY — that identity is the point: the
// check can only compare what it decodes, and a field added to `derive` but
// not to this struct becomes invisible to the gate the moment it is seeded.
// Keep the two in step; comparedFields below is the machine-readable version
// of that promise and the table prints it, so a drift between them is visible
// in the output rather than only in this comment.
type servedDoc struct {
	ID          string        `json:"_id"`
	Title       string        `json:"title"`
	Description string        `json:"description"`
	Concept     string        `json:"concept"`
	Variant     string        `json:"variant"`
	Domain      string        `json:"domain"`
	Direction   string        `json:"direction"`
	Tags        []weightedTag `json:"tags"`
	Source      string        `json:"source"`
}

// comparedFields is the ordered list of document fields the drift check
// compares. `_id` is absent because it is the JOIN KEY, not a compared value —
// an id present on one side only is already a MISSING/EXTRA row.
var comparedFields = []string{
	"title", "description", "concept", "variant", "domain", "direction", "tags", "source",
}

// uncomparedServedKeys are keys the served documents carry that this check
// deliberately does NOT compare, because SEEDING DOES NOT WRITE THEM: the
// system fields Barkpark stamps on every document, plus `main_tag`, which the
// server derives from the weighted `tags` composite rather than reading it off
// the payload. They are named in the table's scope line rather than silently
// excluded — a check credited with "the served catalog matches main" owes the
// reader the boundary of "the catalog".
var uncomparedServedKeys = []string{
	"_createdAt", "_draft", "_publishedId", "_rev", "_type", "_updatedAt", "main_tag",
}

// comparableTags canonicalises the weighted-tags composite for comparison.
// Order is significant and deliberately so: `weightedTags` assigns DESCENDING
// 90/80/70 strengths by header position, so a reordered TAGS header is a real
// derivation change even when the same names come back.
func comparableTags(tags []weightedTag) string {
	b, err := json.Marshal(tags)
	if err != nil {
		// Unreachable for a []weightedTag of plain scalars; a marshal failure
		// must never read as "equal", so return something no other value equals.
		return fmt.Sprintf("<unmarshalable:%v>", err)
	}
	return string(b)
}

// localFields projects a derived payload onto comparedFields.
func localFields(p *payload) map[string]string {
	return map[string]string{
		"title":       p.Title,
		"description": p.Description,
		"concept":     p.Concept,
		"variant":     p.Variant,
		"domain":      p.Domain,
		"direction":   p.Direction,
		"tags":        comparableTags(p.Tags),
		"source":      p.Source,
	}
}

// servedFields projects a served document onto the SAME keys, through the same
// canonicalisation, so the two maps are comparable key by key.
func servedFields(d servedDoc) map[string]string {
	return map[string]string{
		"title":       d.Title,
		"description": d.Description,
		"concept":     d.Concept,
		"variant":     d.Variant,
		"domain":      d.Domain,
		"direction":   d.Direction,
		"tags":        comparableTags(d.Tags),
		"source":      d.Source,
	}
}

// divergentFields returns the compared fields whose values differ, in
// comparedFields order (stable output, never map-iteration order).
func divergentFields(local, served map[string]string) []string {
	var out []string
	for _, f := range comparedFields {
		if local[f] != served[f] {
			out = append(out, f)
		}
	}
	return out
}

// row is one line of the --check comparison table.
type row struct {
	id        string
	localSHA  string   // "" when the command has no local corpus file (EXTRA)
	servedSHA string   // "" when the command is not served (MISSING)
	fields    []string // the compared fields that diverged; empty on MATCH
	status    string   // MATCH | DRIFT | MISSING | EXTRA
}

// fieldsCell renders the divergent-field list for the table.
func (r row) fieldsCell() string {
	if len(r.fields) == 0 {
		return "-"
	}
	return strings.Join(r.fields, ",")
}

// printCheckTable renders the comparison over the union of local and served
// command ids (sorted) and returns the count of non-MATCH rows.
//
// THE STATUS TOKEN IS A CONTRACT, NOT A LABEL. .github/workflows/
// scaffy-catalog-drift.yml greps `[[:space:]](DRIFT|MISSING|EXTRA)$` to tell a
// drift verdict from an UNREACHABLE fetch, and awk-extracts $1 off those same
// lines to build the re-seed list. So the status stays one of exactly
// MATCH|DRIFT|MISSING|EXTRA and stays the LAST field on the line. The finer
// verdict the operator needs — re-seed (source moved) versus investigate the
// parser (metadata moved under an unchanged source) — is carried by the FIELDS
// column and the summary breakdown, NOT by a new status token: a
// "METADATA-DRIFT" status would not match that grep and would have routed a
// real drift into the workflow's UNREACHABLE branch.
func printCheckTable(w io.Writer, server string, payloads []*payload, served map[string]servedDoc) int {
	local := make(map[string]map[string]string, len(payloads))
	for _, p := range payloads {
		local[p.ID] = localFields(p)
	}
	servedF := make(map[string]map[string]string, len(served))
	for id, d := range served {
		servedF[id] = servedFields(d)
	}

	ids := make([]string, 0, len(local)+len(servedF))
	seen := map[string]bool{}
	for id := range local {
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	for id := range servedF {
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	sort.Strings(ids)

	rows := buildRows(ids, local, servedF)
	nonMatch, sourceDrift, metadataOnlyDrift := 0, 0, 0
	for _, r := range rows {
		if r.status == "MATCH" {
			continue
		}
		nonMatch++
		if r.status == "DRIFT" {
			if slicesContains(r.fields, "source") {
				sourceDrift++
			} else {
				metadataOnlyDrift++
			}
		}
	}

	fmt.Fprintf(w, "scaffy catalog drift check — %s (%d local, %d served)\n\n", server, len(local), len(servedF))
	fmt.Fprintf(w, "%-44s  %-8s  %-8s  %-28s  %s\n", "ID", "LOCAL", "SERVED", "DIVERGENT FIELDS", "STATUS")
	fmt.Fprintf(w, "%-44s  %-8s  %-8s  %-28s  %s\n", strings.Repeat("-", 44), "--------", "--------", strings.Repeat("-", 28), "------")
	for _, r := range rows {
		fmt.Fprintf(w, "%-44s  %-8s  %-8s  %-28s  %s\n", r.id, r.localSHA, r.servedSHA, r.fieldsCell(), r.status)
	}
	fmt.Fprintln(w)
	// THE SCOPE LINE. It states what was compared and what was not, so the
	// verdict below it cannot be read as broader than the comparison that
	// produced it.
	fmt.Fprintf(w, "compared per id: %s\n", strings.Join(comparedFields, ", "))
	fmt.Fprintf(w, "not compared (seeding does not write them): %s\n", strings.Join(uncomparedServedKeys, ", "))
	if nonMatch == 0 {
		fmt.Fprintf(w, "%d/%d MATCH — catalog in sync\n", len(rows), len(rows))
	} else {
		fmt.Fprintf(w, "%d/%d MATCH, %d DRIFT/MISSING/EXTRA\n", len(rows)-nonMatch, len(rows), nonMatch)
		if sourceDrift > 0 {
			fmt.Fprintf(w, "  %d with a changed source — re-seed the touched commands (see scaffy/seed/README.md)\n", sourceDrift)
		}
		if metadataOnlyDrift > 0 {
			fmt.Fprintf(w, "  %d whose source is UNCHANGED but whose derived metadata moved — the deriver changed, not the corpus; re-seed, then look at what changed under internal/scaffy/\n", metadataOnlyDrift)
		}
	}
	return nonMatch
}

// buildRows is the row-construction half of printCheckTable, factored out so
// --impact can ask the SAME comparison "which ids are not MATCH" without
// re-implementing the status switch. Two copies of this switch would be two
// definitions of "drift", and the PR-time notice must mean exactly what the
// post-merge gate means.
func buildRows(ids []string, local, servedF map[string]map[string]string) []row {
	rows := make([]row, 0, len(ids))
	for _, id := range ids {
		lf, hasLocal := local[id]
		sf, hasServed := servedF[id]
		var status string
		var diverged []string
		switch {
		case hasLocal && hasServed:
			diverged = divergentFields(lf, sf)
			if len(diverged) == 0 {
				status = "MATCH"
			} else {
				status = "DRIFT"
			}
		case hasLocal && !hasServed:
			status = "MISSING" // in the repo, not served — never seeded
		default:
			status = "EXTRA" // served, no local corpus file backs it
		}
		rows = append(rows, row{
			id:        id,
			localSHA:  sha8(sourceSHA(lf, hasLocal)),
			servedSHA: sha8(sourceSHA(sf, hasServed)),
			fields:    diverged,
			status:    status,
		})
	}
	return rows
}

// sourceSHA returns the hex sha256 of the `source` field of a projected side,
// or "" when that side has no document at all (MISSING/EXTRA).
func sourceSHA(fields map[string]string, present bool) string {
	if !present {
		return ""
	}
	return fmt.Sprintf("%x", sha256.Sum256([]byte(fields["source"])))
}

// slicesContains is the two-line membership test, kept local rather than
// pulling the whole slices package in for one call.
func slicesContains(hay []string, needle string) bool {
	for _, h := range hay {
		if h == needle {
			return true
		}
	}
	return false
}

// sha8 shortens a hex digest to the first 8 chars for the table, rendering a
// missing side as a dash.
func sha8(h string) string {
	if h == "" {
		return "-"
	}
	if len(h) < 8 {
		return h
	}
	return h[:8]
}

// serverURL resolves the catalog host: the `server` field of
// ${XDG_CONFIG_HOME:-~/.config}/barkpark/config.json when present and
// non-empty, else defaultServer. A missing or malformed config is not fatal —
// the audit falls back to the default host.
func serverURL() string {
	var path string
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		path = filepath.Join(xdg, "barkpark", "config.json")
	} else if home, err := os.UserHomeDir(); err == nil {
		path = filepath.Join(home, ".config", "barkpark", "config.json")
	}
	if path != "" {
		if raw, err := os.ReadFile(path); err == nil {
			var cfg struct {
				Server string `json:"server"`
			}
			if json.Unmarshal(raw, &cfg) == nil && strings.TrimSpace(cfg.Server) != "" {
				return strings.TrimRight(strings.TrimSpace(cfg.Server), "/")
			}
		}
	}
	return defaultServer
}

// fetchAttempts and fetchBackoff bound the retry in fetchServed. They are
// variables, not constants, so the tests can drive the retry loop without
// sleeping for seconds.
//
// WHY A RETRY AT ALL, AND WHY IT MUST STAY BOUNDED. Run 32624106095
// (2026-08-23T06:53:32Z) reddened scaffy-catalog-drift with UNREACHABLE; ten
// minutes later run 32624562064 fetched the same host fine and reported 22/22
// MATCH. Nothing about the catalog changed — guerrilla simply did not answer
// that one request. That is 1 spurious red in the gate's first 12 runs on a
// daily cron: roughly one false alarm a month, forever, on a watcher whose
// whole value is that people believe its reds. An alarm that cries wolf
// monthly teaches exactly the scrolling-past this gate was promoted to stop.
//
// WHAT THIS IS NOT. It is NOT a softening of the UNREACHABLE verdict. After
// the attempts are exhausted the error is returned unchanged, runCheck fails,
// no table is printed, and the workflow still reds hard and still names the
// failure UNREACHABLE. "A check that cannot check never reports clean" is
// untouched — retrying only distinguishes "the host is down" from "one packet
// went missing", which the old single-shot fetch could not tell apart.
var (
	fetchAttempts = 3
	fetchBackoff  = 500 * time.Millisecond
)

// fetchServed pulls the PUBLISHED command catalog tokenless and returns a map
// of _id → sha256(source) hex. Every failure path — transport, non-200,
// unreadable body, malformed JSON — is an error so the check fails loud. A
// TRANSIENT failure is retried up to fetchAttempts times with linear backoff;
// a failure that cannot be cured by waiting (a 404, a body that is not the
// envelope) fails on the first attempt so a misconfiguration is reported fast
// instead of being padded out by pointless retries.
func fetchServed(server string) (map[string]servedDoc, error) {
	var lastErr error
	for attempt := 1; attempt <= fetchAttempts; attempt++ {
		out, retryable, err := fetchServedOnce(server)
		if err == nil {
			if attempt > 1 {
				fmt.Fprintf(os.Stderr, "fetched the served catalog on attempt %d/%d (earlier attempt failed: %v)\n",
					attempt, fetchAttempts, lastErr)
			}
			return out, nil
		}
		lastErr = err
		if !retryable || attempt == fetchAttempts {
			break
		}
		fmt.Fprintf(os.Stderr, "attempt %d/%d to fetch the served catalog failed (%v) — retrying in %s\n",
			attempt, fetchAttempts, err, time.Duration(attempt)*fetchBackoff)
		time.Sleep(time.Duration(attempt) * fetchBackoff)
	}
	return nil, lastErr
}

// fetchServedOnce is one attempt. The bool reports whether the failure is
// worth retrying: transport errors, 5xx and 429 are transient; a 4xx other
// than 429 and a body that will not decode are not — waiting cannot fix a
// wrong URL or a non-envelope response.
func fetchServedOnce(server string) (map[string]servedDoc, bool, error) {
	url := server + "/v1/data/query/production/command?limit=100"
	client := &http.Client{Timeout: 20 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, true, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		retryable := resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests
		return nil, retryable, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		// A read that dies mid-body is a transport fault, not a bad catalog.
		return nil, true, err
	}
	// THE ENVELOPE DECODES EVERY FIELD SEEDING WRITES, not {_id, source}.
	// `derive` posts nine fields and the served document carries all nine; a
	// two-field envelope made every verdict in this table a statement about
	// the source string alone, so a change under internal/scaffy/** that alters
	// what the corpus DERIVES TO — header extraction, cmd.Direction(),
	// weightedTags' 90/80/70 ladder — moved the served metadata out from under
	// the check while `source` still matched and the gate printed 22/22 MATCH.
	// internal/scaffy/** is one of this gate's own `on: push: paths:` entries,
	// so it fired on exactly the class it could not see (task-7c037e523ccac6ee).
	var env struct {
		Result struct {
			Documents []servedDoc `json:"documents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, false, fmt.Errorf("decode query envelope: %w", err)
	}
	out := make(map[string]servedDoc, len(env.Result.Documents))
	for _, d := range env.Result.Documents {
		out[d.ID] = d
	}
	return out, false, nil
}
