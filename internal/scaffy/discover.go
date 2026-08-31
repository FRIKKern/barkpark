package scaffy

// discover.go is the engine behind `bp scaffy discover` (leap 1) — the
// deterministic, zero-token git-mining pass that generalizes the canonical
// bash miner (tooling/scaffy-mine/mine.sh, the pinned reference oracle) from
// three hardcoded targets to the whole repository. Three passes ride TWO
// batched `git log` invocations (never a per-commit process storm):
//
//	ACCRETION   — files with high commit count AND high unique-partner
//	              diversity (the revolving-cast registry signature), ranked,
//	              with an uncapped co-change partner count and a ≥2…≥5
//	              support histogram (mine.sh stage 2, generalized per-file).
//	CO-CREATION — same-commit basename-paired creations per suffix rule
//	              (foo.ex + foo_test.exs, .go/.ts/.tsx pairs), strict and
//	              loose, exactly the mine.sh stage-2 matcher generalized.
//	SHAPE       — for the top accretion files, the PURE_ADD / MOSTLY_ADD /
//	              MIXED commit split by numstat (the append-stream signal
//	              that found root.html.heex's 56% append share).
//
// Plus the killer feature: a CATALOG CROSS-REFERENCE — every candidate is
// checked against the served corpus (scaffy/commands/*.scaffy op targets),
// so the output says SERVED / PARTIAL / UNSERVED instead of making the
// reader re-derive coverage by hand.
//
// Determinism (the mine.sh guarantees, kept):
//   - The window derives from the UNTIL commit's own commit day (default:
//     12 calendar months before it), never from wall-clock "now".
//   - --no-merges everywhere; the name-status pass parses renames the same
//     way mine.sh does (R lines are touches, not adds), so the numbers match
//     the canon on the same window.
//   - All output is sorted (commits desc / path asc; count desc / dir asc).
//   - Read-only: only `git log` / `git rev-parse` / `git ls-tree` plus
//     reading the committed catalog. Never writes anything.
//
// Deliberate non-features, inherited from the canon: no nodes.json universe
// gate, no partner caps, no denylist — the counts are frequency evidence,
// not verdicts, and the report says so.

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ErrSinceFormat marks a malformed --since value (neither YYYY-MM-DD nor a
// <N><d|w|m|y> duration). The CLI maps it to a usage error (exit 2).
var ErrSinceFormat = errors.New("since must be YYYY-MM-DD or <N>d|w|m|y (e.g. 12m, 90d)")

// DiscoverOptions configures one Discover run. Zero values mean: repo root
// derived from Dir (or the cwd), Until "HEAD", Since 12 months before the
// until commit's day, MinSupport 5, Top 20, catalog "scaffy/commands".
type DiscoverOptions struct {
	Dir         string // any directory inside the repo; "" = cwd
	Until       string // rev the window is pinned to; "" = HEAD
	Since       string // YYYY-MM-DD or <N>d|w|m|y before the until day; "" = 12m
	MinSupport  int    // minimum commits for an accretion candidate
	Top         int    // accretion candidates reported
	CommandsDir string // catalog dir, repo-root-relative; "" = scaffy/commands
}

// RecentWindowDays is the fixed span (before the until commit's day) of the
// recent sub-window reported alongside the full aggregate. It is a constant,
// not a flag, so the recent column is reproducible from the until commit
// alone — the same honesty guarantee as the main window derivation.
const RecentWindowDays = 90

// DiscoverWindow records exactly which commits were mined, so a reader can
// reproduce every number.
type DiscoverWindow struct {
	Since       string `json:"since"`
	UntilRev    string `json:"until_rev"`
	UntilSHA    string `json:"until_sha"`
	UntilDay    string `json:"until_day"`
	Derivation  string `json:"derivation"`
	NoMerges    bool   `json:"no_merges"`
	Commits     int    `json:"commits"`
	RecentSince string `json:"recent_since"` // start of the last-N-day sub-window (pin-derived)
	RecentDays  int    `json:"recent_days"`  // span of that sub-window, always RecentWindowDays
}

// ShapeSplit is the numstat commit classification for one file:
// PURE_ADD (deletions == 0), MOSTLY_ADD (additions ≥ 3× deletions),
// MIXED (everything else, binary and zero-line commits included).
type ShapeSplit struct {
	PureAdd   int `json:"pure_add"`
	MostlyAdd int `json:"mostly_add"`
	Mixed     int `json:"mixed"`
}

// SupportHistogram is the uncapped partner distribution: how many distinct
// partner files co-changed with the candidate at least N times.
type SupportHistogram struct {
	Ge2 int `json:"ge2"`
	Ge3 int `json:"ge3"`
	Ge4 int `json:"ge4"`
	Ge5 int `json:"ge5"`
}

// Decomposition is the recency-honesty signal: a candidate is DECOMPOSED when
// a single in-window commit gutted the file (see decomposition rule in
// logShapes). It exposes the divergence a 12-month aggregate hides — a file
// whose ranked churn is mostly PRE-decomposition history no longer resembling
// its current shape (the studio_live.ex ghost-vein failure mode).
type Decomposition struct {
	Detected     bool `json:"detected"`
	MaxDelete    int  `json:"max_delete"`    // largest single-commit deletions in the window
	CurrentLines int  `json:"current_lines"` // the file's line count at the until commit
}

// AccretionCandidate is one ranked accretion-file row.
type AccretionCandidate struct {
	Rank          int              `json:"rank"`
	Path          string           `json:"path"`
	Commits       int              `json:"commits"`
	RecentCommits int              `json:"recent_commits"` // commits inside the last-N-day sub-window
	Partners      int              `json:"partners"`       // distinct co-changed files, uncapped
	Support       SupportHistogram `json:"support"`
	Shape         ShapeSplit       `json:"shape"`
	Decomp        Decomposition    `json:"decomposition"`
	Coverage      string           `json:"coverage"` // served | partial | unserved
	CoveredBy     []string         `json:"covered_by,omitempty"`
}

// DirCount is one hot directory of strict co-creation pairs.
type DirCount struct {
	Dir   string `json:"dir"`
	Count int    `json:"count"`
}

// CoCreationRule is one suffix-pair rule's counts across the window.
type CoCreationRule struct {
	SrcSuffix  string     `json:"src_suffix"`
	TestSuffix string     `json:"test_suffix"`
	Strict     int        `json:"strict"` // commits with a basename-matched pair
	Loose      int        `json:"loose"`  // commits adding any src + any test
	TopDirs    []DirCount `json:"top_dirs,omitempty"`
	CoveredBy  []string   `json:"covered_by,omitempty"` // commands creating this pair shape
}

// DiscoverReport is the full result of one run.
type DiscoverReport struct {
	Window          DiscoverWindow       `json:"window"`
	MinSupport      int                  `json:"min_support"`
	Top             int                  `json:"top"`
	CatalogDir      string               `json:"catalog_dir"`
	CatalogCommands int                  `json:"catalog_commands"`
	Accretion       []AccretionCandidate `json:"accretion"`
	CoCreation      []CoCreationRule     `json:"co_creation"`
	Note            string               `json:"note"`
	DurationMS      int64                `json:"duration_ms"`
}

// DiscoverNote is the honesty line every rendering must carry.
const DiscoverNote = "counts are FREQUENCY evidence, not verdicts — a candidate earns a command (or a cut) only through the survey step"

// coCreationRules is the fixed, ordered suffix-pair table. The .ex rule is
// byte-compatible with mine.sh stage 2 (its strict/loose figures reproduce
// the canon on the same window). Test suffixes are always matched BEFORE the
// source suffix, so foo_test.go never lands in the .go source bucket.
var coCreationRules = []struct{ src, test string }{
	{".ex", "_test.exs"},
	{".go", "_test.go"},
	{".ts", ".test.ts"},
	{".tsx", ".test.tsx"},
}

// commitRec is one mined commit: its commit day (YYYY-MM-DD, from %cI, used to
// place the commit in the recent sub-window), every touched path, and the
// ADDED subset.
type commitRec struct {
	day   string
	files []string
	added []string
}

// Discover runs the three mining passes + the catalog cross-reference.
// Read-only; see the file header for the determinism contract.
func Discover(opts DiscoverOptions) (*DiscoverReport, error) {
	start := time.Now()
	dir := opts.Dir
	if dir == "" {
		wd, err := os.Getwd()
		if err != nil {
			return nil, err
		}
		dir = wd
	}
	root, err := gitOutput(dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return nil, fmt.Errorf("not a git repository (rev-parse --show-toplevel): %w", err)
	}
	rootDir := strings.TrimSpace(string(root))

	until := opts.Until
	if until == "" {
		until = "HEAD"
	}
	untilSHA, err := gitOutput(rootDir, "rev-parse", "--verify", until+"^{commit}")
	if err != nil {
		return nil, fmt.Errorf("until rev %q not found: %w", until, err)
	}
	sha := strings.TrimSpace(string(untilSHA))
	untilISO, err := gitOutput(rootDir, "show", "-s", "--format=%cI", sha)
	if err != nil {
		return nil, err
	}
	untilDay := strings.SplitN(strings.TrimSpace(string(untilISO)), "T", 2)[0]

	since, derivation, err := deriveSince(opts.Since, untilDay)
	if err != nil {
		return nil, err
	}

	// The recent sub-window: RecentWindowDays before the until commit's day,
	// pin-derived exactly like the main window (never wall-clock). A commit is
	// "recent" when its day is on or after recentSince.
	untilT, perr := time.Parse("2006-01-02", untilDay)
	if perr != nil {
		return nil, fmt.Errorf("cannot parse until commit day %q: %w", untilDay, perr)
	}
	recentSince := untilT.AddDate(0, 0, -RecentWindowDays).Format("2006-01-02")

	minSupport := opts.MinSupport
	if minSupport <= 0 {
		minSupport = 5
	}
	top := opts.Top
	if top <= 0 {
		top = 20
	}
	catalogDir := opts.CommandsDir
	if catalogDir == "" {
		catalogDir = "scaffy/commands"
	}

	// ── Pass 1: ONE name-status stream feeds accretion + co-creation ────────
	commits, err := logNameStatus(rootDir, since, sha)
	if err != nil {
		return nil, err
	}

	// Existence filter: a candidate must exist at the until commit — dead
	// registries and local ledgers are history, not work.
	existing, err := lsTreeSet(rootDir, sha)
	if err != nil {
		return nil, err
	}

	touch := map[string]int{}         // file → commits touching it
	recentTouch := map[string]int{}   // file → commits touching it inside the recent sub-window
	fileCommits := map[string][]int{} // file → commit indexes
	for i, c := range commits {
		recent := c.day >= recentSince // YYYY-MM-DD strings sort chronologically
		for _, f := range c.files {
			touch[f]++
			if recent {
				recentTouch[f]++
			}
			fileCommits[f] = append(fileCommits[f], i)
		}
	}

	var paths []string
	for f, n := range touch {
		if n >= minSupport && existing[f] {
			paths = append(paths, f)
		}
	}
	sort.Slice(paths, func(i, j int) bool {
		if touch[paths[i]] != touch[paths[j]] {
			return touch[paths[i]] > touch[paths[j]]
		}
		return paths[i] < paths[j]
	})
	if len(paths) > top {
		paths = paths[:top]
	}

	catalog := loadCatalog(rootDir, catalogDir)

	candidates := make([]AccretionCandidate, 0, len(paths))
	for rank, f := range paths {
		support := map[string]int{}
		for _, idx := range fileCommits[f] {
			for _, other := range commits[idx].files {
				if other != f {
					support[other]++
				}
			}
		}
		var hist SupportHistogram
		for _, v := range support {
			if v >= 2 {
				hist.Ge2++
			}
			if v >= 3 {
				hist.Ge3++
			}
			if v >= 4 {
				hist.Ge4++
			}
			if v >= 5 {
				hist.Ge5++
			}
		}
		coverage, coveredBy := catalog.coverage(f)
		candidates = append(candidates, AccretionCandidate{
			Rank:          rank + 1,
			Path:          f,
			Commits:       touch[f],
			RecentCommits: recentTouch[f],
			Partners:      len(support),
			Support:       hist,
			Coverage:      coverage,
			CoveredBy:     coveredBy,
		})
	}

	// ── Pass 2 (batched): numstat over the candidate paths only → shapes +
	// the decomposition flag. Current line counts (one batched cat-file over
	// the ≤top candidate blobs at the until commit) supply the denominator for
	// the >50% gut test — not a per-file storm, a single bounded process.
	if len(paths) > 0 {
		currentLines, lerr := blobLineCounts(rootDir, sha, paths)
		if lerr != nil {
			return nil, lerr
		}
		shapes, decomp, serr := logShapes(rootDir, since, sha, paths, currentLines)
		if serr != nil {
			return nil, serr
		}
		for i := range candidates {
			p := candidates[i].Path
			candidates[i].Shape = shapes[p]
			d := decomp[p]
			d.CurrentLines = currentLines[p]
			candidates[i].Decomp = d
		}
	}

	// ── Co-creation rules over the ADDED sets of pass 1 ─────────────────────
	rules := mineCoCreation(commits, catalog)

	return &DiscoverReport{
		Window: DiscoverWindow{
			Since:       since,
			UntilRev:    until,
			UntilSHA:    sha,
			UntilDay:    untilDay,
			Derivation:  derivation,
			NoMerges:    true,
			Commits:     len(commits),
			RecentSince: recentSince,
			RecentDays:  RecentWindowDays,
		},
		MinSupport:      minSupport,
		Top:             top,
		CatalogDir:      catalogDir,
		CatalogCommands: len(catalog.commands),
		Accretion:       candidates,
		CoCreation:      rules,
		Note:            DiscoverNote,
		DurationMS:      time.Since(start).Milliseconds(),
	}, nil
}

var (
	sinceDateRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
	sinceDurRe  = regexp.MustCompile(`^(\d+)([dwmy])$`)
)

// CheckSinceFormat validates a --since value without a repository: "" (the
// default), a YYYY-MM-DD date, or a <N>d|w|m|y duration. Anything else is
// ErrSinceFormat — the CLI maps it to a usage error before touching git.
func CheckSinceFormat(raw string) error {
	if raw == "" || sinceDurRe.MatchString(raw) {
		return nil
	}
	if sinceDateRe.MatchString(raw) {
		if _, err := time.Parse("2006-01-02", raw); err != nil {
			return fmt.Errorf("%w: %q", ErrSinceFormat, raw)
		}
		return nil
	}
	return fmt.Errorf("%w: %q", ErrSinceFormat, raw)
}

// deriveSince resolves the --since flag against the until commit's day.
// "" → 12 calendar months before the until day (the mine.sh derivation);
// YYYY-MM-DD → literal; <N>d|w|m|y → that span before the until day. Never
// wall-clock relative.
func deriveSince(raw, untilDay string) (since, derivation string, err error) {
	day, perr := time.Parse("2006-01-02", untilDay)
	if perr != nil {
		return "", "", fmt.Errorf("cannot parse until commit day %q: %w", untilDay, perr)
	}
	switch {
	case raw == "":
		return day.AddDate(0, -12, 0).Format("2006-01-02"),
			"default: 12 calendar months before the until commit's day (pin-derived, not wall-clock)", nil
	case sinceDateRe.MatchString(raw):
		if _, perr := time.Parse("2006-01-02", raw); perr != nil {
			return "", "", fmt.Errorf("%w: %q", ErrSinceFormat, raw)
		}
		return raw, "explicit --since date", nil
	default:
		m := sinceDurRe.FindStringSubmatch(raw)
		if m == nil {
			return "", "", fmt.Errorf("%w: %q", ErrSinceFormat, raw)
		}
		n, _ := strconv.Atoi(m[1])
		var d time.Time
		switch m[2] {
		case "d":
			d = day.AddDate(0, 0, -n)
		case "w":
			d = day.AddDate(0, 0, -7*n)
		case "m":
			d = day.AddDate(0, -n, 0)
		case "y":
			d = day.AddDate(-n, 0, 0)
		}
		return d.Format("2006-01-02"),
			fmt.Sprintf("--since %s before the until commit's day (pin-derived, not wall-clock)", raw), nil
	}
}

// gitOutput runs one read-only git command rooted at dir.
func gitOutput(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("git %s: %s", strings.Join(args, " "), msg)
	}
	return out, nil
}

const commitSentinel = "@@C@@"

// logNameStatus is the shared skeleton: ONE `git log --name-status` stream,
// split on the sentinel into per-commit file sets. Rename/copy lines
// ("R100\told\tnew") contribute their NEW path as a touch, never an add —
// exactly the mine.sh stage-2 parse, so the numbers reproduce the canon.
// gitSince renders the window start for git. A bare date would make git's
// approxidate fill in the CURRENT time-of-day — a hidden wall-clock wobble on
// the boundary day — so the argument pins to midnight: the whole boundary day
// is always in the window, on any run, at any hour.
func gitSince(day string) string { return day + "T00:00:00" }

func logNameStatus(root, since, until string) ([]commitRec, error) {
	// The sentinel line carries the committer date (%cI); its first 10 chars
	// are the commit day, used to place the commit in the recent sub-window.
	// The SHA is not parsed anywhere, so nothing is lost by dropping %H.
	out, err := gitOutput(root, "log", "--no-merges", "--since="+gitSince(since),
		"--format="+commitSentinel+"%cI", "--name-status", until)
	if err != nil {
		return nil, err
	}
	var commits []commitRec
	var cur *commitRec
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, commitSentinel) {
			commits = append(commits, commitRec{})
			cur = &commits[len(commits)-1]
			if iso := strings.TrimPrefix(line, commitSentinel); len(iso) >= 10 {
				cur.day = iso[:10]
			}
			continue
		}
		if line == "" || cur == nil {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 2 {
			continue
		}
		status := fields[0][0]
		p := fields[len(fields)-1] // renames/copies: take the NEW path
		cur.files = append(cur.files, p)
		if status == 'A' {
			cur.added = append(cur.added, p)
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return commits, nil
}

// lsTreeSet is the set of paths existing at the until commit.
func lsTreeSet(root, until string) (map[string]bool, error) {
	out, err := gitOutput(root, "ls-tree", "-r", "--name-only", until)
	if err != nil {
		return nil, err
	}
	set := map[string]bool{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		if p := sc.Text(); p != "" {
			set[p] = true
		}
	}
	return set, sc.Err()
}

// logShapes classifies every in-window commit touching each candidate by its
// numstat: PURE_ADD (del == 0, add > 0), MOSTLY_ADD (add ≥ 3×del), MIXED
// (everything else — binary "-" and zero-line commits included). ONE batched
// invocation over the candidate pathspec; --no-renames keeps numstat paths
// brace-free (shape figures are not part of the mine.sh parity contract).
//
// The same stream also detects DECOMPOSITION — the recency-honesty flag. Each
// numstat line IS one commit's delta for that file, so a "single commit gutted
// the file" test needs no grouping. The rule (documented in the help text):
//
//	del > add  AND  del > currentLines[f]/2
//
// i.e. a net-removing commit whose deletions exceed half the file's CURRENT
// (until-commit) line count — the honest approximation of ">50% of the file's
// lines at that time" (current lines stand in for the pre-commit count, which
// numstat deltas cannot reconstruct across a partial window). currentLines is
// the pre-computed batched line count; a 0 (missing/binary) never flags.
func logShapes(root, since, until string, paths []string, currentLines map[string]int) (map[string]ShapeSplit, map[string]Decomposition, error) {
	args := []string{"log", "--no-merges", "--no-renames", "--since=" + gitSince(since),
		"--format=" + commitSentinel + "%H", "--numstat", until, "--"}
	args = append(args, paths...)
	out, err := gitOutput(root, args...)
	if err != nil {
		return nil, nil, err
	}
	want := map[string]bool{}
	for _, p := range paths {
		want[p] = true
	}
	shapes := map[string]ShapeSplit{}
	decomp := map[string]Decomposition{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, commitSentinel) || line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 3 || !want[fields[2]] {
			continue
		}
		f := fields[2]
		add, aerr := strconv.Atoi(fields[0])
		del, derr := strconv.Atoi(fields[1])
		s := shapes[f]
		switch {
		case aerr != nil || derr != nil: // binary "-"
			s.Mixed++
		case del == 0 && add > 0:
			s.PureAdd++
		case del > 0 && add >= 3*del:
			s.MostlyAdd++
		default:
			s.Mixed++
		}
		shapes[f] = s
		// Decomposition: a single net-removing commit that gutted >50% of the
		// file's current line count.
		if aerr == nil && derr == nil && del > add && currentLines[f] > 0 && del > currentLines[f]/2 {
			d := decomp[f]
			d.Detected = true
			if del > d.MaxDelete {
				d.MaxDelete = del
			}
			decomp[f] = d
		}
	}
	return shapes, decomp, sc.Err()
}

// blobLineCounts returns the line count of each path's blob at the until
// commit — ONE batched `git cat-file --batch` over the ≤top candidates (fed
// their `<until>:<path>` refs on stdin), never a per-file process storm. A
// missing or binary blob counts as 0 (and so never trips the decomposition
// test). Deterministic: pinned to the until SHA, independent of the worktree.
func blobLineCounts(root, until string, paths []string) (map[string]int, error) {
	counts := map[string]int{}
	if len(paths) == 0 {
		return counts, nil
	}
	var in bytes.Buffer
	for _, p := range paths {
		in.WriteString(until + ":" + p + "\n")
	}
	cmd := exec.Command("git", "-C", root, "cat-file", "--batch")
	cmd.Stdin = &in
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("git cat-file --batch: %s", msg)
	}
	// Output per request: a header line "<sha> <type> <size>\n", then <size>
	// content bytes, then a trailing "\n"; or "<ref> missing\n" for an absent
	// blob. Requests come back in input order.
	pos := 0
	for _, p := range paths {
		nl := bytes.IndexByte(out[pos:], '\n')
		if nl < 0 {
			break
		}
		header := string(out[pos : pos+nl])
		pos += nl + 1
		fields := strings.Fields(header)
		if len(fields) < 3 || fields[1] == "missing" {
			counts[p] = 0 // "<ref> missing" (2 fields) or any non-blob header
			continue
		}
		size, serr := strconv.Atoi(fields[2])
		if serr != nil || pos+size > len(out) {
			counts[p] = 0
			break
		}
		content := out[pos : pos+size]
		pos += size
		if pos < len(out) && out[pos] == '\n' {
			pos++ // skip the record-terminating newline cat-file appends
		}
		n := bytes.Count(content, []byte{'\n'})
		if len(content) > 0 && content[len(content)-1] != '\n' {
			n++ // a final line with no trailing newline still counts
		}
		counts[p] = n
	}
	return counts, nil
}

// mineCoCreation applies the fixed suffix-pair rules to every commit's ADDED
// set. Strict counts a commit ONCE if any added base+src has a basename-
// matched added base+test (dir-independent — the mine.sh matcher); loose
// counts a commit adding any src-suffix file AND any test-suffix file.
func mineCoCreation(commits []commitRec, cat *catalogIndex) []CoCreationRule {
	rules := make([]CoCreationRule, len(coCreationRules))
	dirCounts := make([]map[string]int, len(coCreationRules))
	for i, r := range coCreationRules {
		rules[i] = CoCreationRule{SrcSuffix: r.src, TestSuffix: r.test}
		dirCounts[i] = map[string]int{}
	}
	for _, c := range commits {
		for i, r := range coCreationRules {
			srcs := map[string]string{} // base → dir
			tests := map[string]bool{}
			for _, f := range c.added {
				base := path.Base(f)
				switch {
				case strings.HasSuffix(base, r.test):
					tests[strings.TrimSuffix(base, r.test)] = true
				case strings.HasSuffix(base, r.src):
					srcs[strings.TrimSuffix(base, r.src)] = path.Dir(f)
				}
			}
			if len(srcs) > 0 && len(tests) > 0 {
				rules[i].Loose++
			}
			matched := false
			for base, dir := range srcs {
				if tests[base] {
					if !matched {
						rules[i].Strict++ // commit counts once (mine.sh)
						matched = true
					}
					dirCounts[i][dir]++ // every matched pair feeds the dir evidence
				}
			}
		}
	}
	for i := range rules {
		var dirs []DirCount
		for d, n := range dirCounts[i] {
			dirs = append(dirs, DirCount{Dir: d, Count: n})
		}
		sort.Slice(dirs, func(a, b int) bool {
			if dirs[a].Count != dirs[b].Count {
				return dirs[a].Count > dirs[b].Count
			}
			return dirs[a].Dir < dirs[b].Dir
		})
		if len(dirs) > 3 {
			dirs = dirs[:3]
		}
		rules[i].TopDirs = dirs
		rules[i].CoveredBy = cat.pairCoverage(coCreationRules[i].src, coCreationRules[i].test)
	}
	return rules
}

// ── Catalog cross-reference ──────────────────────────────────────────────────

// catalogCommand is one parsed served command's coverage surface.
//
// Coverage precision rules, chosen against the live corpus's false positives:
//   - Literal targets (any op) claim their exact file.
//   - Templated IN/DELETE targets ({{token}} → *, segment-scoped) claim files
//     of that SHAPE — a real but weaker claim, reported as shape-level.
//   - Templated CREATE targets claim NOTHING per-file: a command that creates
//     new files (add-plugin's plugins/{{.plugin_name}}.ex) does not serve an
//     EXISTING file that merely matches the pattern (plugins/capabilities.ex
//     is the registry, not a plugin). They still feed pair-shape coverage.
type catalogCommand struct {
	concept string
	ensure  bool     // ensure-* commands guarantee a fragment, not the file's accretion stream → PARTIAL
	targets []string // literal op-target paths
	globs   []string // templated IN/DELETE targets, {{token}} → * (segment-scoped)
	creates []string // CREATE FILE targets, raw (for pair-shape coverage)
}

type catalogIndex struct{ commands []catalogCommand }

// loadCatalog parses every *.scaffy under root/dir into a coverage index. A
// missing or empty catalog degrades to zero commands (everything UNSERVED) —
// discover must run on a bare checkout.
func loadCatalog(root, dir string) *catalogIndex {
	idx := &catalogIndex{}
	files, err := filepath.Glob(filepath.Join(root, dir, "*.scaffy"))
	if err != nil {
		return idx
	}
	sort.Strings(files)
	for _, f := range files {
		src, rerr := os.ReadFile(f)
		if rerr != nil {
			continue
		}
		cmd, _ := Parse(f, src)
		if cmd == nil {
			continue
		}
		stem := strings.TrimSuffix(filepath.Base(f), ".scaffy")
		concept := stem
		if cmd.Header.Concept != nil && cmd.Header.Concept.Value != "" {
			concept = cmd.Header.Concept.Value
		}
		cc := catalogCommand{concept: concept, ensure: strings.HasPrefix(stem, "ensure-")}
		addTarget := func(p string, create bool) {
			if p == "" {
				return
			}
			if create {
				cc.creates = append(cc.creates, p)
			}
			if !strings.Contains(p, "{{") {
				cc.targets = append(cc.targets, p)
				return
			}
			if create {
				// Templated CREATEs never claim existing files (see the type doc).
				return
			}
			glob := tokenRe.ReplaceAllString(p, "*")
			// A whole-path token (`{{.TargetFile}}` → "*") matches everything
			// and would mark the entire repo served — skip it as universal.
			if strings.Trim(glob, "*") == "" {
				return
			}
			cc.globs = append(cc.globs, glob)
		}
		for _, op := range cmd.Ops {
			switch o := op.(type) {
			case *CreateFile:
				addTarget(o.Path.Value, true)
			case *DeleteFile:
				addTarget(o.Path.Value, false)
			case *InOp:
				addTarget(o.Path.Value, false)
			}
		}
		idx.commands = append(idx.commands, cc)
	}
	return idx
}

// coverage classifies one path against the catalog: "served" only when a
// non-ensure command targets it LITERALLY; "partial" when the best claim is
// an ensure-* command (a planted anchor, not the accretion stream) or a
// shape-level templated-IN match; "unserved" otherwise. CoveredBy lists the
// matching concepts, sorted, suffixed "(ensure)" / "(shape)" by claim kind.
func (c *catalogIndex) coverage(p string) (string, []string) {
	var concepts []string
	served := false
	for _, cmd := range c.commands {
		literal := false
		for _, t := range cmd.targets {
			if t == p {
				literal = true
				break
			}
		}
		shape := false
		if !literal {
			for _, g := range cmd.globs {
				if ok, _ := path.Match(g, p); ok {
					shape = true
					break
				}
			}
		}
		if !literal && !shape {
			continue
		}
		name := cmd.concept
		switch {
		case cmd.ensure:
			name += " (ensure)"
		case shape:
			name += " (shape)"
		default:
			served = true
		}
		concepts = append(concepts, name)
	}
	if len(concepts) == 0 {
		return "unserved", nil
	}
	sort.Strings(concepts)
	if served {
		return "served", concepts
	}
	return "partial", concepts
}

// pairCoverage lists the concepts whose CREATE targets include both a
// src-suffix and a test-suffix file — the commands already mechanizing this
// co-creation shape. Shape-level coverage is inherently partial: it says
// "some clusters of this pair are commanded", never "all".
func (c *catalogIndex) pairCoverage(src, test string) []string {
	var concepts []string
	for _, cmd := range c.commands {
		hasSrc, hasTest := false, false
		for _, t := range cmd.creates {
			base := path.Base(t)
			switch {
			case strings.HasSuffix(base, test):
				hasTest = true
			case strings.HasSuffix(base, src):
				hasSrc = true
			}
		}
		if hasSrc && hasTest {
			concepts = append(concepts, cmd.concept)
		}
	}
	sort.Strings(concepts)
	return concepts
}
