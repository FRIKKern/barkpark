package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// censusSite is one derived write call site: the file, the enclosing function
// and the line, kept so a red can point at the source instead of a count.
type censusSite struct {
	File string
	Func string
	Line int
	Text string
}

// censusKey is the (file, function) pair the census is keyed on.
type censusKey struct{ File, Func string }

var (
	// censusRawWriteSignal is signal (a): a line that names an HTTP write
	// method. It is deliberately BROADER than `http.NewRequest` — the built-ins
	// reach the wire through at least four wrappers (doRequest, supportMainJSON,
	// cp.do, tinkerRequest), and a signal keyed on one of them would have
	// missed the other three. Comment lines are skipped by the caller.
	censusRawWriteSignal = regexp.MustCompile(`http\.Method(Post|Put|Patch|Delete)\b|"(POST|PUT|PATCH|DELETE)"`)

	// censusFuncDecl finds the enclosing function for a line.
	censusFuncDecl = regexp.MustCompile(`^func (?:\([^)]*\) )?(\w+)`)

	// censusAPIClientMethodDecl finds an internal/apiclient *Client method.
	censusAPIClientMethodDecl = regexp.MustCompile(`^func \(c \*Client\) (\w+)`)
	censusPlainFuncDecl       = regexp.MustCompile(`^func (\w+)`)
)

// TestBuiltinWriteCensusIsDerivedFromSource is criterion c0's instrument: it
// recomputes the built-in write population FROM SOURCE and requires the census
// table to match it exactly, in both directions.
//
// A row missing from the census is a built-in write receipt nobody decided
// about. A census row with no site is a decision about code that no longer
// exists. Both are reds, and the message names the file:line either way.
func TestBuiltinWriteCensusIsDerivedFromSource(t *testing.T) {
	root := repoRootForCensus(t)
	sites := deriveBuiltinWriteSites(t, root)

	if len(sites) == 0 {
		// NON-VACUITY. A derivation that finds nothing would make this test
		// pass over an empty census forever — the exact vacuity this epic
		// exists to kill. The floor is not a guess: the census itself declares
		// more than 25 sites, so a derivation that collapses is a red here
		// before it is a green anywhere.
		t.Fatal("the derivation found ZERO built-in write sites — the scan is broken, not the tree")
	}

	derived := map[censusKey][]censusSite{}
	for _, s := range sites {
		derived[censusKey{s.File, s.Func}] = append(derived[censusKey{s.File, s.Func}], s)
	}

	censused := map[censusKey]builtinWriteReceipt{}
	for _, r := range builtinWriteCensus {
		k := censusKey{r.File, r.Func}
		if _, dup := censused[k]; dup {
			t.Errorf("census has TWO rows for %s:%s — one row per function, with Sites carrying the count", r.File, r.Func)
		}
		censused[k] = r
	}

	for _, k := range sortedCensusKeys(derived) {
		row, ok := censused[k]
		if !ok {
			t.Errorf("UNCENSUSED built-in write receipt: %s:%s\n  %s\n"+
				"  A built-in that writes and renders its own receipt must carry a builtinWriteCensus row saying\n"+
				"  either that it is screened through writeReceiptVerdict, or WHY its receipt cannot lie.",
				k.File, k.Func, siteLines(derived[k]))
			continue
		}
		if row.Sites != len(derived[k]) {
			t.Errorf("%s:%s declares Sites=%d but the source has %d write call sites:\n%s",
				k.File, k.Func, row.Sites, len(derived[k]), siteLines(derived[k]))
		}
	}
	for _, k := range sortedCensusKeys(censused) {
		if _, ok := derived[k]; !ok {
			t.Errorf("STALE census row: %s:%s no longer has any write call site in the source — delete the row",
				k.File, k.Func)
		}
	}
}

// TestBuiltinWriteCensusRowsAreWellFormed is the census's own shape gate: every
// row must carry a class, a disposition from the closed set, and — the point of
// c1 — a Why. An empty Why on a cannot-lie row would be an exemption with no
// argument, which is how a fence quietly becomes an allowlist.
func TestBuiltinWriteCensusRowsAreWellFormed(t *testing.T) {
	for _, r := range builtinWriteCensus {
		name := r.File + ":" + r.Func
		switch r.Class {
		case machineRendered, humanOnly:
		default:
			t.Errorf("%s: Class %q is not %q or %q", name, r.Class, machineRendered, humanOnly)
		}
		switch r.Disposition {
		case dispScreened, dispCannotLie, dispOutOfFence:
		default:
			t.Errorf("%s: Disposition %q is not one of %q/%q/%q", name, r.Disposition, dispScreened, dispCannotLie, dispOutOfFence)
		}
		if strings.TrimSpace(r.Why) == "" {
			t.Errorf("%s: empty Why — every disposition must state its argument", name)
		}
		if r.Sites < 1 {
			t.Errorf("%s: Sites=%d", name, r.Sites)
		}
		if strings.TrimSpace(r.Endpoint) == "" {
			t.Errorf("%s: empty Endpoint", name)
		}
	}
}

// deriveBuiltinWriteSites recomputes the population. See the doc comment on
// builtinWriteReceipt for what the two signals can and cannot see.
func deriveBuiltinWriteSites(t *testing.T, root string) []censusSite {
	t.Helper()
	writeMethods := deriveAPIClientWriteMethods(t, root)
	if len(writeMethods) == 0 {
		t.Fatal("derived ZERO apiclient write methods — signal (b) is broken")
	}
	methodAlt := strings.Join(writeMethods, "|")

	var out []censusSite
	for _, path := range builtinSourceFiles(t, root) {
		raw, err := os.ReadFile(filepath.Join(root, path))
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		src := string(raw)

		// Signal (b) is scoped per file to expressions the file itself proves
		// are an *apiclient.Client: a var assigned from apiclient.New, a
		// parameter typed *apiclient.Client, or a local constructor declared to
		// return one. Without that scoping, `.Create(`/`.Delete(` would match
		// os.Create and the hcloud SDK and the census would be noise.
		var clientPat *regexp.Regexp
		if strings.Contains(src, "internal/apiclient") {
			exprs := map[string]bool{}
			for _, m := range regexp.MustCompile(`(\w+)\s*:?=\s*apiclient\.New\(`).FindAllStringSubmatch(src, -1) {
				exprs[m[1]] = true
			}
			for _, m := range regexp.MustCompile(`(\w+)\s+\*apiclient\.Client`).FindAllStringSubmatch(src, -1) {
				exprs[m[1]] = true
			}
			for _, m := range regexp.MustCompile(`func (\w+)\([^)]*\)\s*\*apiclient\.Client`).FindAllStringSubmatch(src, -1) {
				exprs[m[1]] = true
			}
			if len(exprs) > 0 {
				names := make([]string, 0, len(exprs))
				for e := range exprs {
					names = append(names, regexp.QuoteMeta(e))
				}
				sort.Strings(names)
				clientPat = regexp.MustCompile(
					`(?:^|[^\w.])(` + strings.Join(names, "|") + `)(?:\([^()]*\))?\.(` + methodAlt + `)\(`)
			}
		}

		fn := ""
		for i, line := range strings.Split(src, "\n") {
			if m := censusFuncDecl.FindStringSubmatch(line); m != nil {
				fn = m[1]
			}
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "//") || strings.HasPrefix(trimmed, "*") {
				continue
			}
			hit := censusRawWriteSignal.MatchString(line)
			if !hit && clientPat != nil {
				hit = clientPat.MatchString(line)
			}
			if hit {
				out = append(out, censusSite{File: path, Func: fn, Line: i + 1, Text: trimmed})
			}
		}
	}
	return out
}

// deriveAPIClientWriteMethods returns the EXPORTED internal/apiclient *Client
// methods that write, transitively: a method whose own body names an HTTP write
// method, plus anything that calls one. Derived, not listed, so a new write
// helper in apiclient widens signal (b) automatically.
func deriveAPIClientWriteMethods(t *testing.T, root string) []string {
	t.Helper()
	dir := filepath.Join(root, "internal", "apiclient")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read internal/apiclient: %v", err)
	}
	bodies := map[string]string{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		cur, buf := "", []string{}
		for _, line := range strings.Split(string(raw), "\n") {
			m := censusAPIClientMethodDecl.FindStringSubmatch(line)
			if m == nil {
				m = censusPlainFuncDecl.FindStringSubmatch(line)
			}
			if m != nil {
				if cur != "" {
					bodies[cur] = strings.Join(buf, "\n")
				}
				cur, buf = m[1], []string{line}
				continue
			}
			if cur != "" {
				buf = append(buf, line)
			}
		}
		if cur != "" {
			bodies[cur] = strings.Join(buf, "\n")
		}
	}

	writes := map[string]bool{}
	for name, body := range bodies {
		if censusRawWriteSignal.MatchString(body) {
			writes[name] = true
		}
	}
	for changed := true; changed; {
		changed = false
		for name, body := range bodies {
			if writes[name] {
				continue
			}
			for w := range writes {
				if regexp.MustCompile(`\b` + regexp.QuoteMeta(w) + `\s*\(`).MatchString(body) {
					writes[name] = true
					changed = true
					break
				}
			}
		}
	}

	var exported []string
	for name := range writes {
		if name != "" && name[0] >= 'A' && name[0] <= 'Z' {
			exported = append(exported, regexp.QuoteMeta(name))
		}
	}
	sort.Strings(exported)
	return exported
}

// builtinSourceFiles is the scanned tree: internal/cli and its subpackages,
// minus tests, minus the MCP surface (#15900/#15917 own it) and minus run.go
// (the manifest dispatch, which IS the fence).
func builtinSourceFiles(t *testing.T, root string) []string {
	t.Helper()
	var out []string
	base := filepath.Join(root, "internal", "cli")
	err := filepath.Walk(base, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		name := info.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") ||
			strings.HasPrefix(name, "mcp") || name == "run.go" {
			return nil
		}
		rel, rerr := filepath.Rel(root, p)
		if rerr != nil {
			return rerr
		}
		out = append(out, filepath.ToSlash(rel))
		return nil
	})
	if err != nil {
		t.Fatalf("walk internal/cli: %v", err)
	}
	sort.Strings(out)
	return out
}

func repoRootForCensus(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for dir := wd; ; {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("no go.mod above %s", wd)
		}
		dir = parent
	}
}

func sortedCensusKeys[V any](m map[censusKey]V) []censusKey {
	out := make([]censusKey, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Func < out[j].Func
	})
	return out
}

func siteLines(sites []censusSite) string {
	var b strings.Builder
	for _, s := range sites {
		fmt.Fprintf(&b, "    %s:%d  %s\n", s.File, s.Line, s.Text)
	}
	return strings.TrimRight(b.String(), "\n")
}
