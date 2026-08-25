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
// tokenless, compares sha256(source) per command id, prints a table, and
// exits nonzero on ANY non-MATCH. A command file edited without a re-seed is
// exactly the drift class this catches. It fails LOUD on any network error —
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
	commandsDir := flag.String("commands", "scaffy/commands", "directory of .scaffy corpus files")
	outDir := flag.String("out", "scaffy/seed/out", "directory to write one <_id>.json payload per command (derived; never committed)")
	check := flag.Bool("check", false, "audit mode: derive in memory (no out/ writes), fetch the served catalog tokenless, compare sha256(source) per command id, print a table, exit nonzero on any drift")
	flag.Parse()

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
	files, err := filepath.Glob(filepath.Join(commandsDir, "*.scaffy"))
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
// writes), fetches the served catalog tokenless, compares sha256(source) per
// command id, prints a table, and returns a non-nil error (→ exit 1) on ANY
// non-MATCH. Network failures also return an error: a check that cannot check
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
		return fmt.Errorf("%d command(s) drifted from the served catalog — re-seed the touched commands (see scaffy/seed/README.md)", drifted)
	}
	return nil
}

// row is one line of the --check comparison table.
type row struct {
	id        string
	localSHA  string // "" when the command has no local corpus file (EXTRA)
	servedSHA string // "" when the command is not served (MISSING)
	status    string // MATCH | DRIFT | MISSING | EXTRA
}

// printCheckTable renders the comparison over the union of local and served
// command ids (sorted) and returns the count of non-MATCH rows.
func printCheckTable(w io.Writer, server string, payloads []*payload, served map[string]string) int {
	local := make(map[string]string, len(payloads))
	for _, p := range payloads {
		local[p.ID] = fmt.Sprintf("%x", sha256.Sum256([]byte(p.Source)))
	}

	ids := make([]string, 0, len(local)+len(served))
	seen := map[string]bool{}
	for id := range local {
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	for id := range served {
		if !seen[id] {
			ids = append(ids, id)
			seen[id] = true
		}
	}
	sort.Strings(ids)

	rows := make([]row, 0, len(ids))
	nonMatch := 0
	for _, id := range ids {
		ls, hasLocal := local[id]
		ss, hasServed := served[id]
		var status string
		switch {
		case hasLocal && hasServed && ls == ss:
			status = "MATCH"
		case hasLocal && hasServed:
			status = "DRIFT"
		case hasLocal && !hasServed:
			status = "MISSING" // in the repo, not served — never seeded
		default:
			status = "EXTRA" // served, no local corpus file backs it
		}
		if status != "MATCH" {
			nonMatch++
		}
		rows = append(rows, row{id: id, localSHA: sha8(ls), servedSHA: sha8(ss), status: status})
	}

	fmt.Fprintf(w, "scaffy catalog drift check — %s (%d local, %d served)\n\n", server, len(local), len(served))
	fmt.Fprintf(w, "%-44s  %-8s  %-8s  %s\n", "ID", "LOCAL", "SERVED", "STATUS")
	fmt.Fprintf(w, "%-44s  %-8s  %-8s  %s\n", strings.Repeat("-", 44), "--------", "--------", "------")
	for _, r := range rows {
		fmt.Fprintf(w, "%-44s  %-8s  %-8s  %s\n", r.id, r.localSHA, r.servedSHA, r.status)
	}
	fmt.Fprintln(w)
	if nonMatch == 0 {
		fmt.Fprintf(w, "%d/%d MATCH — catalog in sync\n", len(rows), len(rows))
	} else {
		fmt.Fprintf(w, "%d/%d MATCH, %d DRIFT/MISSING/EXTRA\n", len(rows)-nonMatch, len(rows), nonMatch)
	}
	return nonMatch
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
func fetchServed(server string) (map[string]string, error) {
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
func fetchServedOnce(server string) (map[string]string, bool, error) {
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
	var env struct {
		Result struct {
			Documents []struct {
				ID     string `json:"_id"`
				Source string `json:"source"`
			} `json:"documents"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, false, fmt.Errorf("decode query envelope: %w", err)
	}
	out := make(map[string]string, len(env.Result.Documents))
	for _, d := range env.Result.Documents {
		out[d.ID] = fmt.Sprintf("%x", sha256.Sum256([]byte(d.Source)))
	}
	return out, false, nil
}
