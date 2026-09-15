package apiclient

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// ── The defect this file gates ───────────────────────────────────────────────
//
// internal/apiclient hand-encodes its /v1 routes as string concatenation
// (scopedURL("/v1/data/mutate/" + c.Dataset)) rather than routing through
// manifest.BuildURL. Those literals DUPLICATE manifest-declared commands. A
// server-side route rename updates the manifest and the generic dispatch path
// and STRANDS this second client — silently, until a user hits the dead route.
// Two copies of one truth, and nothing reds.
//
// ── Why this test parses the SOURCE instead of listing the paths ─────────────
//
// The obvious shape for this gate is a table of the fifteen-odd literals. That
// shape is the ORIGINAL DEFECT REBUILT INSIDE ITS OWN GUARD: a hand-written
// list is a snapshot of one afternoon, and the sixteenth literal added next
// week is invisible to it. So the literal set is DERIVED, by parsing
// client.go / schema.go / change.go with go/parser and reassembling every "+"
// concatenation chain that starts with "/v1". A new literal is picked up the
// moment it is written, with no list to remember to update.
//
// Proven, not asserted: adding a bogus literal
//
//	endpoint := c.scopedURL("/v1/data/quokka/" + c.Dataset)
//
// to client.go makes TestManifestPathDrift red with
//
//	client.go:407: /v1/data/quokka/* — no manifest command declares this path
//
// and removing it greens. (Measured 2026-09-15. That is the Go->fixture
// direction; TestManifestPathDriftDetectsRenamedRoute below covers the
// fixture->Go direction. They catch different bugs: a test that hardcoded its
// expectations would pass one and fail the other.)
//
// ── Why a local struct and not internal/manifest ─────────────────────────────
//
// internal/manifest imports internal/apiclient (manifest/fetch.go), so this
// package cannot import it back. The fixture is decoded through the minimal
// shape the gate actually reads.

// fixturePath is the committed capture of GET /v1/capabilities. Its provenance
// and the one command that refreshes it live in the fixture's own `_fixture`
// header and in testdata/regen-capabilities.sh — a second copy of a route table
// with no mechanical refresh is the disease, not the cure.
const fixturePath = "testdata/capabilities.json"

// driftScanFiles are the files the criterion names. Adding a file here widens
// the sweep; nothing else needs to change.
var driftScanFiles = []string{"client.go", "schema.go", "change.go"}

type fixtureHeader struct {
	What       string `json:"what"`
	Source     string `json:"source"`
	CapturedAt string `json:"captured_at"`
	Regenerate string `json:"regenerate"`
}

type fixtureCommand struct {
	ID   string `json:"id"`
	Noun string `json:"noun"`
	Verb string `json:"verb"`
	HTTP struct {
		Method       string `json:"method"`
		PathTemplate string `json:"path_template"`
	} `json:"http"`
}

type fixtureManifest struct {
	Fixture  fixtureHeader    `json:"_fixture"`
	AuthTier string           `json:"auth_tier"`
	Commands []fixtureCommand `json:"commands"`
}

// undeclaredRoutes are Go literals that hit a REAL server route which the
// capabilities manifest does not declare as a command. Each is a route the CLI
// reaches directly rather than through the manifest dispatch path, so there is
// no path_template to compare against and the gate has nothing to say.
//
// This is an exception table, and an exception table is the very thing this
// test refuses elsewhere — so it is ratcheted in BOTH directions:
//   - a literal that is neither matched nor listed here is a FAILURE (a new
//     hand-rolled route has to be justified in writing, here, once);
//   - a listed literal that the manifest HAS started declaring is also a
//     FAILURE, so the table cannot quietly accumulate dead entries and go
//     vacuous. That is the direction nobody remembers to check.
var undeclaredRoutes = map[string]string{
	"/v1/data/listen/*":  "SSE change stream. Not a manifest command: the manifest describes request/response commands, and `bp listen` dials the stream directly.",
	"/v1/data/export/*":  "NDJSON bulk export. Streaming download, likewise not modelled as a manifest command.",
	"/v1/structure/*":    "Studio's rendered structure tree (host groups + plugin panels). Served for the Studio/TUI navigator, never advertised as a bp verb.",
	"/v1/tasks/*/labels": "Task label add/remove. The route exists and the CLI posts to it, but capabilities declares no task.labels command — so the manifest cannot police this one and a rename here would strand it. FLAGGED, not excused.",
}

// ── the sweep ────────────────────────────────────────────────────────────────

func TestManifestPathDrift(t *testing.T) {
	m := loadDriftFixture(t)
	lits := scanV1Literals(t, driftScanFiles)

	// An absence is never caught by inspection. If the parse walked the files
	// and found nothing, every assertion below passes VACUOUSLY. Floor it.
	if len(lits) < 10 {
		t.Fatalf("scanned %v and reassembled only %d /v1 literals — the parser is not seeing the source; every assertion below would be vacuous", driftScanFiles, len(lits))
	}
	if len(m.Commands) < 100 {
		t.Fatalf("fixture holds %d commands — not a live admin surface; the sweep would be vacuous", len(m.Commands))
	}

	templates := make([]string, 0, len(m.Commands))
	for _, c := range m.Commands {
		if c.HTTP.PathTemplate != "" {
			templates = append(templates, c.HTTP.PathTemplate)
		}
	}

	matchedExceptions := map[string]string{}
	for _, l := range lits {
		if id, ok := matchTemplate(l.path, m.Commands); ok {
			t.Logf("%s:%d  %-34s -> %s", l.file, l.line, l.path, id)
			if _, listed := undeclaredRoutes[l.path]; listed {
				matchedExceptions[l.path] = id
			}
			continue
		}
		if _, listed := undeclaredRoutes[l.path]; listed {
			continue
		}
		t.Errorf("%s:%d: %s — no manifest command declares this path.\n"+
			"  Either the server route was renamed (regenerate: %s) or this Go literal is a new hand-rolled route.\n"+
			"  A hand-rolled route must be justified in undeclaredRoutes in this file.\n"+
			"  Nearest manifest templates: %v",
			l.file, l.line, l.path, m.Fixture.Regenerate, nearest(l.path, templates))
	}

	// The other ratchet direction: an exception that the manifest now declares
	// is a dead entry, and a dead entry is how an exception table rots into a
	// blanket.
	for p, id := range matchedExceptions {
		t.Errorf("undeclaredRoutes lists %q, but the manifest now declares it as command %q — delete the exception so the gate polices this route.", p, id)
	}

	// An exception for a literal that no longer exists in the source is the
	// same rot, from the other end.
	present := map[string]bool{}
	for _, l := range lits {
		present[l.path] = true
	}
	for p := range undeclaredRoutes {
		if !present[p] {
			t.Errorf("undeclaredRoutes lists %q, but no such literal exists in %v any more — delete the stale exception.", p, driftScanFiles)
		}
	}
}

// TestManifestPathDriftFixtureProvenance holds the fixture to the thing that
// keeps it from becoming a second source of truth: a header that says where it
// came from and how to refresh it. A fixture whose provenance has been edited
// away is one hand-edit from being the Go code asserted against itself.
func TestManifestPathDriftFixtureProvenance(t *testing.T) {
	m := loadDriftFixture(t)
	if m.AuthTier != "admin" {
		t.Errorf("fixture auth_tier = %q, want \"admin\" — /v1/capabilities is tier-projected, and a lower-tier capture silently drops the routes this gate polices", m.AuthTier)
	}
	for name, got := range map[string]string{
		"_fixture.what":        m.Fixture.What,
		"_fixture.source":      m.Fixture.Source,
		"_fixture.captured_at": m.Fixture.CapturedAt,
		"_fixture.regenerate":  m.Fixture.Regenerate,
	} {
		if strings.TrimSpace(got) == "" {
			t.Errorf("%s is empty — the fixture has lost its provenance", name)
		}
	}
	script := m.Fixture.Regenerate
	if script == "" {
		return
	}
	// The documented regeneration command must be a file that EXISTS and is
	// executable. "Documented" as prose is how a fixture rots.
	rel := strings.TrimPrefix(script, "internal/apiclient/")
	st, err := os.Stat(rel)
	if err != nil {
		t.Fatalf("_fixture.regenerate = %q, but %q does not exist: %v", script, rel, err)
	}
	if st.Mode()&0o111 == 0 {
		t.Errorf("%s is not executable — the documented refresh must be runnable, not prose", rel)
	}
}

// TestManifestPathDriftDetectsRenamedRoute is the MUTATION ARM in the
// fixture->Go direction: rename a route in a copy of the fixture and the
// matcher must strand the Go literal that used to reach it, BY NAME.
//
// It runs the same matchTemplate the sweep runs, against a mutated command
// list, so it proves the sweep's detector — not a parallel reimplementation of
// it that could agree with the sweep while both are wrong.
func TestManifestPathDriftDetectsRenamedRoute(t *testing.T) {
	m := loadDriftFixture(t)
	const victim = "/v1/data/mutate/:dataset"
	const stranded = "/v1/data/mutate/*"

	// Precondition, asserted rather than assumed: the literal matches BEFORE
	// the rename. A control that fires on a subject that was already broken
	// measures nothing.
	if _, ok := matchTemplate(stranded, m.Commands); !ok {
		t.Fatalf("precondition failed: %s does not match the UNMUTATED fixture — the rename below would prove nothing", stranded)
	}
	found := false
	for i := range m.Commands {
		if m.Commands[i].HTTP.PathTemplate == victim {
			m.Commands[i].HTTP.PathTemplate = "/v1/data/mutate-v2/:dataset"
			found = true
		}
	}
	if !found {
		t.Fatalf("precondition failed: fixture declares no %s to rename", victim)
	}

	if id, ok := matchTemplate(stranded, m.Commands); ok {
		t.Fatalf("renamed %s in the fixture and %s STILL matched (as %q) — the gate would not notice a server rename", victim, stranded, id)
	}

	// And the failure must NAME the stranded literal, not just fail.
	msg := driftFailureMessage(stranded)
	if !strings.Contains(msg, stranded) {
		t.Errorf("drift failure message does not name the stranded literal: %q", msg)
	}

	// Restore and re-assert green, in-process: the same list, unmutated, matches.
	fresh := loadDriftFixture(t)
	if _, ok := matchTemplate(stranded, fresh.Commands); !ok {
		t.Errorf("restoring the fixture did not green %s", stranded)
	}
}

func driftFailureMessage(p string) string {
	return p + " — no manifest command declares this path"
}

// ── source scanning ──────────────────────────────────────────────────────────

type v1Literal struct {
	file string
	line int
	path string // normalized template: dynamic segments rendered as "*"
}

// scanV1Literals reassembles every string-concatenation chain in the given
// files whose value begins with "/v1", rendering each non-literal operand as
// "*". Comments are not BasicLits, so prose mentioning a route is naturally
// excluded — which a grep-based version of this test would not manage.
//
// Every SITE is returned, not every distinct path: two call sites posting to
// the same route are two places a rename can strand, and a red should name the
// one the reader has to open.
func scanV1Literals(t *testing.T, files []string) []v1Literal {
	t.Helper()
	var out []v1Literal
	fset := token.NewFileSet()
	for _, name := range files {
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		consumed := map[ast.Node]bool{}
		ast.Inspect(f, func(n ast.Node) bool {
			switch node := n.(type) {
			case *ast.BinaryExpr:
				if node.Op != token.ADD || consumed[n] {
					return true
				}
				// Claim the whole chain so its inner literals are not
				// re-reported as standalone fragments.
				ast.Inspect(node, func(m ast.Node) bool {
					if m != n {
						consumed[m] = true
					}
					return true
				})
				if s := renderConcat(node); strings.HasPrefix(s, "/v1") {
					out = append(out, v1Literal{file: name, line: fset.Position(node.Pos()).Line, path: normalizeTemplate(s)})
				}
			case *ast.BasicLit:
				if node.Kind != token.STRING || consumed[n] {
					return true
				}
				v, err := strconv.Unquote(node.Value)
				if err != nil || !strings.HasPrefix(v, "/v1") {
					return true
				}
				out = append(out, v1Literal{file: name, line: fset.Position(node.Pos()).Line, path: normalizeTemplate(v)})
			}
			return true
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].file != out[j].file {
			return out[i].file < out[j].file
		}
		return out[i].line < out[j].line
	})
	return out
}

// renderConcat flattens an additive expression tree left-to-right: string
// literals contribute their value, everything else contributes "*".
func renderConcat(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.BinaryExpr:
		if x.Op == token.ADD {
			return renderConcat(x.X) + renderConcat(x.Y)
		}
		return "*"
	case *ast.ParenExpr:
		return renderConcat(x.X)
	case *ast.BasicLit:
		if x.Kind == token.STRING {
			if v, err := strconv.Unquote(x.Value); err == nil {
				return v
			}
		}
		return "*"
	default:
		return "*"
	}
}

// normalizeTemplate strips the query string and collapses runs of "*" so
// "/v1/graph/" + esc(id) + "?drafts=true" reads as "/v1/graph/*".
func normalizeTemplate(s string) string {
	if i := strings.IndexAny(s, "?#"); i >= 0 {
		s = s[:i]
	}
	for strings.Contains(s, "**") {
		s = strings.ReplaceAll(s, "**", "*")
	}
	if len(s) > 1 {
		s = strings.TrimRight(s, "/")
	}
	return s
}

// ── matching ─────────────────────────────────────────────────────────────────

// matchTemplate reports whether any command's path_template can produce the Go
// literal, returning the command id of the first match.
//
// Segment rules:
//   - a manifest ":placeholder" accepts a Go "*" or a Go literal segment (the
//     CLI pins :type to "paper" in one call site — that is a legal binding);
//   - a Go "*" requires a placeholder: a dynamic value cannot be assumed to
//     equal a fixed route segment;
//   - otherwise the segments must be equal.
func matchTemplate(goPath string, cmds []fixtureCommand) (string, bool) {
	gs := strings.Split(goPath, "/")
	for _, c := range cmds {
		tmpl := c.HTTP.PathTemplate
		if tmpl == "" {
			continue
		}
		ts := strings.Split(strings.TrimRight(tmpl, "/"), "/")
		if len(ts) != len(gs) {
			continue
		}
		ok := true
		for i := range ts {
			switch {
			case strings.HasPrefix(ts[i], ":"):
				// placeholder: accepts anything, including a pinned literal
			case gs[i] == "*":
				ok = false
			case gs[i] != ts[i]:
				ok = false
			}
			if !ok {
				break
			}
		}
		if ok {
			id := c.ID
			if id == "" {
				id = c.Noun + "." + c.Verb
			}
			return id, true
		}
	}
	return "", false
}

// nearest returns the templates sharing the longest leading path prefix, so a
// red points at the rename instead of making the reader diff 212 routes.
func nearest(goPath string, templates []string) []string {
	gs := strings.Split(goPath, "/")
	best, bestN := []string{}, 0
	for _, tmpl := range templates {
		ts := strings.Split(tmpl, "/")
		n := 0
		for n < len(gs) && n < len(ts) && gs[n] == ts[n] {
			n++
		}
		switch {
		case n > bestN:
			best, bestN = []string{tmpl}, n
		case n == bestN && n > 1 && len(best) < 4:
			best = append(best, tmpl)
		}
	}
	return best
}

func loadDriftFixture(t *testing.T) *fixtureManifest {
	t.Helper()
	raw, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatalf("read %s: %v (regenerate with testdata/regen-capabilities.sh)", fixturePath, err)
	}
	var m fixtureManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("decode %s: %v", fixturePath, err)
	}
	return &m
}
