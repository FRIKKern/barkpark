package main

// --impact is the PR-TIME half of the scaffy catalog drift story.
//
// THE GAP IT FILLS. scaffy-catalog-drift.yml is a post-merge WATCHER: it fires
// on push-to-main and on a daily cron, and its own header says why it can be
// nothing else — "drift is a serve-side condition, so the PR diff that
// introduces it is exactly what a pre-merge run cannot see". True of that
// workflow, not of the world: a PR's head tree can be derived and compared to
// the served catalog before the merge, which is precisely what this mode does.
// The author learns at review time that merging will put the served catalog
// behind main, instead of a watcher learning it hours later.
//
// WHAT IT READS, AND WHY THAT SET IS DERIVED. A notice that fires on every PR
// is noise that gets tuned out, so this mode says nothing unless the diff
// touches what the DERIVER ACTUALLY READS. That set is two things and both are
// computed, never listed:
//
//  1. THE CORPUS — `defaultCommandsDir + "/" + corpusGlobPattern`, the exact
//     two identifiers deriveAll globs. Move the corpus and this follows.
//
//  2. THE DERIVER CODE — every first-party package in the TRANSITIVE IMPORT
//     CLOSURE of this program, walked from go.mod's module path with go/parser.
//     Today that is scaffy/seed + internal/scaffy. Add an import of
//     internal/foo tomorrow and internal/foo joins the read set with no edit
//     here. This is the point: an enumeration is a snapshot, a predicate is a
//     rule. scaffy-catalog-drift.yml's own `on: push: paths:` block is the
//     snapshot version of this same set, and it is a hand-written list.
//
// WHY THE CLOSURE AND NOT JUST THE CORPUS. A change under internal/scaffy that
// alters what the SAME bytes derive to — header extraction, cmd.Direction(),
// weightedTags' 90/80/70 ladder — drifts the served metadata with every
// corpus file untouched. That class already cost this area one blind gate
// (task-7c037e523ccac6ee).
//
// VERDICTS AND EXIT CODES — the three are distinguishable on purpose, because
// this row's own defect is a failed read rendering as a clean bill of health:
//
//	0  QUIET      nothing to say: the diff touches no read path, OR it does and
//	              the head tree still matches the served catalog. stdout EMPTY.
//	2  CANNOT READ the diff touches a read path but the verdict could not be
//	              computed — catalog unreachable, served catalog empty, or the
//	              deriver produced zero commands. NOT "no drift".
//	3  NOTICE     merging will put the named commands behind the served catalog.
//
// EXIT 3 IS INFORMATIONAL, NOT A GATE. See the WHERE THIS RENDERS section of
// scaffy/seed/README.md: this binary can compute the verdict, but nothing in
// this fence can force a reviewer to look at it. Do not describe it as
// blocking until something actually blocks on it.

import (
	"bufio"
	"fmt"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Exit codes. They are a contract: a caller distinguishes CANNOT READ from
// QUIET by code alone, without parsing prose.
const (
	impactQuiet      = 0
	impactCannotRead = 2
	impactNotice     = 3
)

// deriverPkgRel is the module-relative directory of THIS program — the entry
// point of the import closure below. It is the one path that cannot itself be
// derived at runtime (a binary does not know where its source lived), so
// TestDeriverPkgRelIsThisPackage asserts it resolves to the package that
// actually defines deriveAll: if this program moves, that test reds.
const deriverPkgRel = "scaffy/seed"

// readPaths is the deriver's read set: one corpus glob plus the directories of
// every first-party package it transitively imports.
type readPaths struct {
	corpusGlob string   // slash-separated, e.g. "scaffy/commands/*.scaffy"
	pkgDirs    []string // slash-separated module-relative dirs, sorted
}

// modulePath reads the module path out of go.mod. It is the prefix that tells
// a first-party import from a dependency, so it is read, never assumed.
func modulePath(root string) (string, error) {
	raw, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		return "", fmt.Errorf("read go.mod: %w", err)
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if rest, ok := strings.CutPrefix(line, "module "); ok {
			if p := strings.TrimSpace(rest); p != "" {
				return p, nil
			}
		}
	}
	return "", fmt.Errorf("no module line in %s", filepath.Join(root, "go.mod"))
}

// firstPartyClosure walks the transitive import graph from entry, keeping only
// packages under modPath, and returns their module-relative directories sorted.
//
// _test.go files are excluded deliberately: a test's imports are not part of
// derivation, and editing a test cannot move what the corpus derives to. The
// file-level predicate below excludes _test.go for the same reason, so the two
// halves agree.
func firstPartyClosure(root, modPath, entry string) ([]string, error) {
	seen := map[string]bool{}
	var walk func(imp string) error
	walk = func(imp string) error {
		if seen[imp] {
			return nil
		}
		seen[imp] = true
		rel := strings.TrimPrefix(strings.TrimPrefix(imp, modPath), "/")
		dir := filepath.Join(root, filepath.FromSlash(rel))
		entries, err := os.ReadDir(dir)
		if err != nil {
			return fmt.Errorf("package %s: %w", imp, err)
		}
		fset := token.NewFileSet()
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
				continue
			}
			f, err := parser.ParseFile(fset, filepath.Join(dir, name), nil, parser.ImportsOnly)
			if err != nil {
				return fmt.Errorf("parse %s: %w", filepath.Join(dir, name), err)
			}
			for _, spec := range f.Imports {
				p, err := strconv.Unquote(spec.Path.Value)
				if err != nil {
					continue
				}
				if p == modPath || strings.HasPrefix(p, modPath+"/") {
					if err := walk(p); err != nil {
						return err
					}
				}
			}
		}
		return nil
	}
	if err := walk(entry); err != nil {
		return nil, err
	}
	dirs := make([]string, 0, len(seen))
	for imp := range seen {
		dirs = append(dirs, strings.TrimPrefix(strings.TrimPrefix(imp, modPath), "/"))
	}
	sort.Strings(dirs)
	return dirs, nil
}

// deriverReadPaths computes the whole read set from source.
func deriverReadPaths(root, commandsDir string) (readPaths, error) {
	modPath, err := modulePath(root)
	if err != nil {
		return readPaths{}, err
	}
	dirs, err := firstPartyClosure(root, modPath, modPath+"/"+deriverPkgRel)
	if err != nil {
		return readPaths{}, err
	}
	return readPaths{
		corpusGlob: path.Join(filepath.ToSlash(commandsDir), corpusGlobPattern),
		pkgDirs:    dirs,
	}, nil
}

// impactSet is the intersection of a PR's changed paths with the read set.
type impactSet struct {
	corpus  []string // touched corpus files, sorted
	deriver []string // touched first-party .go files in the closure, sorted
}

func (i impactSet) empty() bool { return len(i.corpus) == 0 && len(i.deriver) == 0 }

// intersect applies the predicate to a changed-path list.
func (rp readPaths) intersect(changed []string) impactSet {
	inClosure := map[string]bool{}
	for _, d := range rp.pkgDirs {
		inClosure[d] = true
	}
	var out impactSet
	for _, c := range changed {
		c = strings.TrimSpace(filepath.ToSlash(c))
		if c == "" {
			continue
		}
		if ok, _ := path.Match(rp.corpusGlob, c); ok {
			out.corpus = append(out.corpus, c)
			continue
		}
		if strings.HasSuffix(c, ".go") && !strings.HasSuffix(c, "_test.go") && inClosure[path.Dir(c)] {
			out.deriver = append(out.deriver, c)
		}
	}
	sort.Strings(out.corpus)
	sort.Strings(out.deriver)
	return out
}

// readChangedPaths reads one repo-relative path per line; "-" means stdin.
func readChangedPaths(r io.Reader, pathArg string) ([]string, error) {
	if pathArg != "-" {
		f, err := os.Open(pathArg)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		r = f
	}
	var out []string
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		if line := strings.TrimSpace(sc.Text()); line != "" {
			out = append(out, line)
		}
	}
	return out, sc.Err()
}

// runImpact is the whole mode. It returns the exit code and writes the notice
// (if any) to stdout; stdout is EMPTY on impactQuiet, which is what makes
// "surfaces nothing" mechanically checkable by a caller.
func runImpact(stdout, stderr io.Writer, root, commandsDir, changedFilesPath string) int {
	rp, err := deriverReadPaths(root, commandsDir)
	if err != nil {
		// The predicate itself could not be computed. That is not "no impact":
		// we do not know whether the diff touches a read path, so it takes the
		// CANNOT READ door, never the quiet one.
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: could not derive the deriver's read paths: %v\n\n%s", err, cannotReadFooter)
		return impactCannotRead
	}

	changed, err := readChangedPaths(os.Stdin, changedFilesPath)
	if err != nil {
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: could not read the changed-file list %q: %v\n\n%s", changedFilesPath, err, cannotReadFooter)
		return impactCannotRead
	}

	imp := rp.intersect(changed)
	if imp.empty() {
		// THE HALF THAT MATTERS. A diff that touches nothing the deriver reads
		// cannot move the served catalog, so nothing is rendered at all — no
		// header, no "all clear", no line. An all-clear on every PR is the
		// noise that gets a notice tuned out inside a week.
		fmt.Fprintf(stderr, "scaffy catalog impact: %d changed path(s), none under %s or the deriver closure (%s) — quiet.\n",
			len(changed), rp.corpusGlob, strings.Join(rp.pkgDirs, ", "))
		return impactQuiet
	}

	payloads, err := deriveAll(commandsDir)
	if err != nil {
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: the deriver refused this tree: %v\n\n%s", err, cannotReadFooter)
		return impactCannotRead
	}
	if len(payloads) == 0 {
		// Unreachable today (deriveAll errors on an empty glob) and guarded
		// anyway: a zero-command derivation must never be read as "nothing
		// drifts". A zero that came from a parse error looks exactly like a
		// real zero, and only this branch tells them apart from in-sync.
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: the deriver produced ZERO commands from %s — a zero corpus cannot be compared to anything, and it is not a clean bill of health.\n\n%s", rp.corpusGlob, cannotReadFooter)
		return impactCannotRead
	}

	server := serverURL()
	served, err := fetchServed(server)
	if err != nil {
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: could not fetch the served catalog from %s: %v\n\n  This PR touches what the deriver reads, so it MIGHT put the catalog behind main.\n  The fetch failed, so nobody knows which. This is NOT \"no drift\".\n\n%s", server, err, cannotReadFooter)
		return impactCannotRead
	}
	if len(served) == 0 {
		fmt.Fprintf(stdout, "SCAFFY CATALOG IMPACT: CANNOT READ\n\n  reason: %s answered, but the served catalog holds ZERO command documents.\n  Either the catalog was never seeded or the query returned an envelope this check could not read.\n  Comparing %d local commands against nothing would report every one of them MISSING, which is a claim about the catalog this run cannot support.\n\n%s", server, len(payloads), cannotReadFooter)
		return impactCannotRead
	}

	notice := buildNotice(server, rp, imp, payloads, served)
	if len(notice.attributed) == 0 {
		// THE FALSE-FIRE GUARD. The diff touched a read path, the catalog was
		// read, and the head tree still matches it for everything this diff can
		// account for. Nothing is rendered: a notice that fires when the
		// catalog is already in sync is exactly the cry-wolf this mode exists
		// to avoid.
		fmt.Fprintf(stderr, "scaffy catalog impact: %d read path(s) touched, catalog read from %s (%d served), head tree matches for all of them — quiet.\n",
			len(imp.corpus)+len(imp.deriver), server, len(served))
		return impactQuiet
	}
	notice.render(stdout)
	return impactNotice
}

const cannotReadFooter = "  CANNOT READ is a distinct verdict (exit 2) from QUIET (exit 0) precisely so it\n" +
	"  cannot be mistaken for one. A check that cannot check never reports clean.\n"

// attributedRow is one command this PR is responsible for putting behind the
// served catalog.
type attributedRow struct {
	id     string
	status string   // DRIFT | MISSING | EXTRA
	fields []string // divergent compared fields; empty for MISSING/EXTRA
	file   string   // the corpus file, when one backs it
}

type notice struct {
	server      string
	rp          readPaths
	imp         impactSet
	attributed  []attributedRow
	preexisting int // non-MATCH rows this diff does NOT account for
	localCount  int
	servedCount int
}

// deriverCanAccountFor decides whether a touched DERIVER file can explain this
// row. A deriver change can move derived metadata — title, direction, the
// weighted-tag ladder — with every corpus byte untouched, so those rows are
// fairly billed to it.
//
// IT CANNOT MOVE `source`. `derive` copies the raw file bytes verbatim, so a
// source-only divergence is by construction a CORPUS change or a served
// catalog that was never re-seeded — never a derivation change. Nor can it
// create a MISSING or an EXTRA, which are corpus-structure facts.
//
// THIS IS NOT A REFINEMENT FOR ITS OWN SAKE. It was found by running the real
// thing: this PR touches only scaffy/seed/*.go, main's served catalog happens
// to carry four source-only drifts nobody re-seeded, and the first version
// billed all four to this PR. A notice that hands an author four commands they
// did not touch is the same "tuned out within a week" failure as one that
// fires on every PR, arriving by a different door.
func deriverCanAccountFor(r row, deriverTouched bool) bool {
	if !deriverTouched || r.status != "DRIFT" {
		return false
	}
	for _, f := range r.fields {
		if f != "source" {
			return true
		}
	}
	return false
}

// buildNotice runs the SAME comparison the post-merge gate runs (buildRows over
// localFields/servedFields), then keeps only the non-MATCH rows THIS DIFF CAN
// ACCOUNT FOR.
//
// THE ATTRIBUTION FILTER IS THE MUTATION ARM'S FIRST HALF. Without it, a PR
// editing one command would surface every command a previous un-re-seeded merge
// had already drifted, and "surfaces exactly that command" would be false
// through no fault of the author. Rows outside the attributable set are counted
// and named as pre-existing, never billed to this PR.
func buildNotice(server string, rp readPaths, imp impactSet, payloads []*payload, served map[string]servedDoc) notice {
	local := make(map[string]map[string]string, len(payloads))
	fileOf := make(map[string]string, len(payloads))
	idOfFile := make(map[string]string, len(payloads))
	for _, p := range payloads {
		local[p.ID] = localFields(p)
		fileOf[p.ID] = filepath.ToSlash(p.File)
		idOfFile[filepath.ToSlash(p.File)] = p.ID
	}
	servedF := make(map[string]map[string]string, len(served))
	for id, d := range served {
		servedF[id] = servedFields(d)
	}

	// Attributable ids. A touched corpus file accounts for its own command,
	// whatever the status.
	corpusAttributable := map[string]bool{}
	for _, f := range imp.corpus {
		if id, ok := idOfFile[f]; ok {
			corpusAttributable[id] = true
			continue
		}
		// A corpus file in the diff with no derived payload at head: the PR
		// deletes or renames it, so whatever it backed becomes EXTRA. Every
		// served id with no local file is attributable to that.
		for id := range servedF {
			if _, hasLocal := local[id]; !hasLocal {
				corpusAttributable[id] = true
			}
		}
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

	n := notice{server: server, rp: rp, imp: imp, localCount: len(local), servedCount: len(servedF)}
	for _, r := range buildRows(ids, local, servedF) {
		if r.status == "MATCH" {
			continue
		}
		if !corpusAttributable[r.id] && !deriverCanAccountFor(r, len(imp.deriver) > 0) {
			n.preexisting++
			continue
		}
		n.attributed = append(n.attributed, attributedRow{
			id: r.id, status: r.status, fields: r.fields, file: fileOf[r.id],
		})
	}
	return n
}

func (n notice) render(w io.Writer) {
	fmt.Fprintf(w, "SCAFFY CATALOG IMPACT: DRIFT\n\n")
	fmt.Fprintf(w, "Merging this PR puts the served scaffy catalog at %s BEHIND main\nuntil somebody re-seeds it. %d command(s) will be stale the moment it lands:\n\n",
		n.server, len(n.attributed))
	fmt.Fprintf(w, "  %-44s  %-8s  %-24s  %s\n", "COMMAND", "STATUS", "FIELDS THAT WILL DIVERGE", "CORPUS FILE")
	fmt.Fprintf(w, "  %-44s  %-8s  %-24s  %s\n", strings.Repeat("-", 44), "--------", strings.Repeat("-", 24), strings.Repeat("-", 11))
	for _, r := range n.attributed {
		fields := "-"
		if len(r.fields) > 0 {
			fields = strings.Join(r.fields, ",")
		}
		file := r.file
		if file == "" {
			file = "(no local corpus file — served only)"
		}
		fmt.Fprintf(w, "  %-44s  %-8s  %-24s  %s\n", r.id, r.status, fields, file)
	}
	fmt.Fprintln(w)

	fmt.Fprintf(w, "WHY THIS PR AND NOT ANOTHER\n")
	fmt.Fprintf(w, "  The diff touches paths the deriver actually reads. That set is computed from\n")
	fmt.Fprintf(w, "  scaffy/seed's own source, not listed: the corpus glob %s, plus\n", n.rp.corpusGlob)
	fmt.Fprintf(w, "  the transitive first-party import closure of scaffy/seed (%s).\n", strings.Join(n.rp.pkgDirs, ", "))
	if len(n.imp.corpus) > 0 {
		fmt.Fprintf(w, "  corpus files touched:  %s\n", strings.Join(n.imp.corpus, ", "))
	}
	if len(n.imp.deriver) > 0 {
		fmt.Fprintf(w, "  deriver files touched: %s\n", strings.Join(n.imp.deriver, ", "))
		fmt.Fprintf(w, "  A deriver change can move ANY command's derived metadata with the corpus\n")
		fmt.Fprintf(w, "  bytes untouched, so every command is in scope for attribution here.\n")
	}
	fmt.Fprintln(w)

	fmt.Fprintf(w, "WHO CAN DISCHARGE IT\n")
	fmt.Fprintf(w, "  Not you, and not CI on merge. Re-seeding WRITES to production content, so\n")
	fmt.Fprintf(w, "  scaffy-catalog-drift.yml repairs only on a run that is BOTH human-dispatched\n")
	fmt.Fprintf(w, "  and opted in (charter D100 amendment):\n")
	fmt.Fprintf(w, "    Actions -> scaffy-catalog-drift -> Run workflow, with repair = true\n")
	fmt.Fprintf(w, "  That needs the BARKPARK_SEED_TOKEN repo secret; until it is minted (task\n")
	fmt.Fprintf(w, "  scaffy-backlog-seed-token-mint) the run reds honestly instead of repairing.\n")
	fmt.Fprintf(w, "  Locally, a credentialed operator can re-seed per scaffy/seed/README.md.\n")
	fmt.Fprintf(w, "  Until then every push-to-main and the 06:17 UTC cron will RED main's suite.\n")
	fmt.Fprintln(w)

	if n.preexisting > 0 {
		fmt.Fprintf(w, "NOT BILLED TO THIS PR\n")
		fmt.Fprintf(w, "  %d further command(s) already diverge from the served catalog for reasons\n", n.preexisting)
		fmt.Fprintf(w, "  this diff does not account for. They are pre-existing drift; run\n")
		fmt.Fprintf(w, "  `go run ./scaffy/seed --check` for the full table.\n\n")
	}

	fmt.Fprintf(w, "scope: %d local command(s), %d served; comparison is the same buildRows the\n", n.localCount, n.servedCount)
	fmt.Fprintf(w, "post-merge gate uses, over: %s\n", strings.Join(comparedFields, ", "))
	fmt.Fprintf(w, "ADVISORY: exit 3 is informational. Nothing blocks on it — see the WHERE THIS\n")
	fmt.Fprintf(w, "RENDERS section of scaffy/seed/README.md.\n")
}
