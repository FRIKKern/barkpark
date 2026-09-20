package cli

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// ── The defect class this file gates ────────────────────────────────────────
//
// task-ce8f04315a6d1f10, generalizing PR #14115 (task-c005183551c279c0):
// mediaUploadFileArg decided "this command uploads a file" by testing whether
// the route's PATH TEXT contained the substring "/media" —
//
//	if !strings.Contains(cmd.HTTP.PathTemplate, "/media") { return "", false }
//
// — when the manifest DECLARES that fact structurally, on the arg, as
// `type: "file"`. The giveaway of the class is a whole class being
// unreachable: NO plugin could ever expose an upload verb, because no plugin
// route spells "/media". A legitimate value that does not happen to SPELL the
// token is silently misclassified.
//
// ── Why this is a shape detector and not a list of today's hits ─────────────
//
// An enumeration is a snapshot; a predicate is a rule. The parent row was
// filed against a measured surface of 342 non-test strings.Contains/HasPrefix/
// HasSuffix lines across internal/ and cmd/. Sixteen days later that same
// command answers 403 (+17.5%), and 65 of those call sites did not exist when
// the six lanes swept. A hand-written table of the five instances the lanes
// found (#14115, #14297, #14300, #14304, #14305, #14306) would have been stale
// before it merged. So the guard keys on the SHAPE instead:
//
//	a strings.* MATCHER (isStringMatchFamily: Contains…, HasPrefix,
//	HasSuffix, Index…, LastIndex…, EqualFold, Count, Cut…, SplitN) whose
//	HAYSTACK is a field reached off a value of a manifest.* type, wrappers
//	and all (manifestHaystack looks through strings.ToLower(…), string(…),
//	a helper call) — i.e. code asking a rendered string a question that the
//	same struct already answers with a typed field.
//
// Both halves of that were an enumeration once, and an enumeration is a
// snapshot: the callee set was literally {Contains, HasPrefix, HasSuffix} and
// the haystack had to BE a selector chain, so strings.Index, strings.EqualFold
// and a one-call wrapper each walked past the gate reading as obvious
// instances of the class (task-0ab3dfa73662ee68). Both are predicates now.
//
// ── Why the manifest package itself is (correctly) out of scope ─────────────
//
// The detector binds identifiers by their QUALIFIED type (`manifest.Command`,
// `manifest.Arg`, …), so it sees CONSUMERS of the manifest and never
// internal/manifest's own code, where `Command`/`HTTP` are unqualified. That is
// the right scoping, not an accident: internal/manifest IS the place where a
// path template is legitimately parsed as text (BuildURL, scope.go,
// dataset_scope.go all carry comments telling callers to stop reaching for
// `strings.Contains(tmpl, ":"+n)` and to use those helpers instead). The
// disease is a DISPATCH site re-deriving a declared fact from spelling.
//
// ── Proven, not asserted ────────────────────────────────────────────────────
//
// TestManifestFactDetectorFiresOnTheSeedDefect runs this exact detector over
// the pre-#14115 shape and requires the hit; running it over the real
// internal/cli/run.go at 7d5b948c0^ (the commit before the fix) reports
//
//	run.go, at the sole pre-fix call site: Contains(cmd.HTTP.PathTemplate, …)
//	[cmd is manifest.Command]
//
// and NOTHING else in that 2,700-line file — so the detector is selective, not
// a blanket ban on strings.Contains. TestManifestFactDetectorStaysQuietOn-
// LegitimateStringWork holds the other half: the two lookalikes the prior
// audit examined and correctly CLEARED (one asks whether a URL contains the
// token it genuinely contains — `strings.Contains(rawURL, "?")` at run.go:1905
// and :3746; one matches an EXACT command id with `==`, which is reading the
// declared id, not sniffing it), plus ordinary flag-prefix and media-type
// parsing, must produce zero hits.

// manifestFactHit is one call site where a string match is asked about a
// manifest-declared value.
type manifestFactHit struct {
	Pos  string
	Fn   string // the strings.* matcher: Contains, Index, EqualFold, …
	Expr string // e.g. cmd.HTTP.PathTemplate
	Root string // the identifier
	Type string // the manifest type it is bound to
}

// manifestQualifier is the package name whose types carry the declarations.
const manifestQualifier = "manifest"

// manifestCollectionFields are the fields whose ELEMENTS are manifest values,
// so `for _, a := range cmd.Args` binds `a` even though no type is written.
var manifestCollectionFields = map[string]string{
	"Args":     "Arg",
	"Flags":    "Flag",
	"Commands": "Command",
	"Nouns":    "Noun",
}

// scanManifestFactStringMatches is the whole predicate, in one place, so the
// tree sweep and both controls exercise the SAME code.
func scanManifestFactStringMatches(fset *token.FileSet, f *ast.File) []manifestFactHit {
	return scanWithManifestBindings(fset, f, bindManifestIdents(f))
}

// bindManifestIdents is the BINDING half of the detector, split out from the
// matching half so the reachability floor below can measure it directly.
//
// The split exists because of a measured hole, not for tidiness: every control
// in this file before it was SYNTHETIC — each parses a source string that
// literally spells `manifest.Command`, so each keeps passing no matter what the
// real tree looks like. Nothing asserted that the detector still binds anything
// in the tree it actually gates. See TestManifestFactDetectorReachesTheRealTree.
func bindManifestIdents(f *ast.File) map[string]string {
	return bindDeclaredFactIdents(f, manifestQualifier)
}

// bindDeclaredFactIdents is bindManifestIdents with the declaring package as a
// PARAMETER. The split is what lets the same predicate run over every package
// whose types carry declarations, not just internal/manifest — see
// declared_fact_other_packages_test.go (task-ce8f04315a6d1f10 c0). manifest is
// simply the qualifier the seed defect happened to live under.
func bindDeclaredFactIdents(f *ast.File, qualifier string) map[string]string {
	bound := map[string]string{}
	bind := func(name, typ string) {
		if name != "" && name != "_" {
			bound[name] = typ
		}
	}
	manifestSel := func(e ast.Expr) (string, bool) {
		if st, ok := e.(*ast.StarExpr); ok {
			e = st.X
		}
		if at, ok := e.(*ast.ArrayType); ok {
			e = at.Elt
		}
		s, ok := e.(*ast.SelectorExpr)
		if !ok {
			return "", false
		}
		x, ok := s.X.(*ast.Ident)
		if !ok || x.Name != qualifier {
			return "", false
		}
		return s.Sel.Name, true
	}

	ast.Inspect(f, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.Field: // params, results, receivers, struct fields
			if typ, ok := manifestSel(v.Type); ok {
				for _, nm := range v.Names {
					bind(nm.Name, typ)
				}
			}
		case *ast.ValueSpec: // var x manifest.Command
			if v.Type != nil {
				if typ, ok := manifestSel(v.Type); ok {
					for _, nm := range v.Names {
						bind(nm.Name, typ)
					}
				}
			}
		case *ast.AssignStmt: // x := manifest.Command{...}
			for i, r := range v.Rhs {
				cl, ok := r.(*ast.CompositeLit)
				if !ok || i >= len(v.Lhs) {
					continue
				}
				if typ, ok := manifestSel(cl.Type); ok {
					if id, ok := v.Lhs[i].(*ast.Ident); ok {
						bind(id.Name, typ)
					}
				}
			}
		case *ast.RangeStmt: // for _, a := range cmd.Args
			se, ok := v.X.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			elem, ok := manifestCollectionFields[se.Sel.Name]
			if !ok {
				return true
			}
			// Only when the collection is reached off a value ALREADY bound to a
			// manifest type — an `.Args` field on some unrelated struct is not
			// this. Params are visited before the body they belong to, so the
			// receiving function's `cmd manifest.Command` is already bound here.
			root, _, rootOK := selectorRoot(se.X)
			if !rootOK {
				return true
			}
			if _, isManifest := bound[root]; !isManifest {
				return true
			}
			if id, ok := v.Value.(*ast.Ident); ok {
				bind(id.Name, elem)
			}
		}
		return true
	})
	return bound
}

// scanWithManifestBindings is the MATCHING half: given the identifiers already
// bound to manifest types, report every string match whose haystack is a field
// reached off one of them.
func scanWithManifestBindings(fset *token.FileSet, f *ast.File, bound map[string]string) []manifestFactHit {
	var hits []manifestFactHit
	ast.Inspect(f, func(n ast.Node) bool {
		c, ok := n.(*ast.CallExpr)
		if !ok || len(c.Args) == 0 {
			return true
		}
		fn, ok := c.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		pkg, ok := fn.X.(*ast.Ident)
		if !ok || pkg.Name != "strings" {
			return true
		}
		if !isStringMatchFamily(fn.Sel.Name) {
			return true
		}
		_, root, ok := manifestHaystack(c.Args[0], bound)
		if !ok {
			return true
		}
		hits = append(hits, manifestFactHit{
			Pos:  fset.Position(c.Pos()).String(),
			Fn:   fn.Sel.Name,
			Expr: renderSelector(c.Args[0]),
			Root: root,
			Type: bound[root],
		})
		return true
	})
	return hits
}

// isStringMatchFamily is the CALLEE half of the predicate: does strings.<name>
// ask a question OF its first argument's spelling?
//
// It is a rule, not a list. The first spelling of this gate enumerated exactly
// {Contains, HasPrefix, HasSuffix}, and an enumeration is a snapshot: the same
// defect written with strings.Index, strings.EqualFold or strings.Count walked
// straight past it while reading as an obvious instance of the class
// (task-0ab3dfa73662ee68). Keying on the family PREFIX means the members Go
// adds next — ContainsFunc, CutPrefix, IndexRune — arrive already covered.
//
// Deliberately NOT in the family: the transforming half of the package
// (ToLower, TrimPrefix, Replace, Fields, Join …). Those produce a string; they
// do not decide anything from one, so on their own they are not this defect.
// A transform WRAPPING a match is still caught, because the match above it is
// what is matched and manifestHaystack looks through the wrapper.
func isStringMatchFamily(name string) bool {
	for _, family := range []string{
		"Contains",  // Contains, ContainsAny, ContainsRune, ContainsFunc
		"HasPrefix", // HasPrefix
		"HasSuffix", // HasSuffix
		"Index",     // Index, IndexAny, IndexByte, IndexRune, IndexFunc
		"LastIndex", // LastIndex, LastIndexAny, LastIndexByte
		"EqualFold", // EqualFold
		"Count",     // Count
		"Cut",       // Cut, CutPrefix, CutSuffix
		"SplitN",    // SplitN, SplitAfterN — "the part before the token"
	} {
		if strings.HasPrefix(name, family) {
			return true
		}
	}
	return false
}

// manifestHaystack is the HAYSTACK half: inside a string match's first
// argument, find the field selector reached off an identifier already bound to
// a declaring type, looking THROUGH any wrapping call.
//
// The looking-through is the point. `selectorRoot` alone reports !ok the
// moment arg 0 is a CallExpr, so
//
//	strings.Contains(strings.ToLower(cmd.HTTP.PathTemplate), "/media")
//
// — the same defect with a normalisation step in front of it — was invisible
// to the first spelling of this gate (task-0ab3dfa73662ee68). A conversion
// (`string(cmd.X)`) and a local helper (`norm(cmd.X)`) hid it the same way.
//
// Only arg 0's own subtree is walked: `strings.Contains(line, cmd.HTTP.Method)`
// asks about `line`, and a declared value used as the NEEDLE is reading the
// declaration, not sniffing it.
func manifestHaystack(e ast.Expr, bound map[string]string) (hay ast.Expr, root string, ok bool) {
	switch v := e.(type) {
	case *ast.ParenExpr:
		return manifestHaystack(v.X, bound)
	case *ast.CallExpr:
		for _, a := range v.Args {
			if h, r, found := manifestHaystack(a, bound); found {
				return h, r, true
			}
		}
		return nil, "", false
	}
	r, depth, rootOK := selectorRoot(e)
	// depth 0 means the haystack is a bare identifier (a line, a rawURL, a
	// flag token) — free text, not a declared field.
	if !rootOK || depth == 0 {
		return nil, "", false
	}
	if _, isBound := bound[r]; !isBound {
		return nil, "", false
	}
	return e, r, true
}

// selectorRoot walks a.b.c down to `a`, reporting how many selectors it peeled.
func selectorRoot(e ast.Expr) (root string, depth int, ok bool) {
	for {
		s, isSel := e.(*ast.SelectorExpr)
		if !isSel {
			break
		}
		depth++
		e = s.X
	}
	id, isIdent := e.(*ast.Ident)
	if !isIdent {
		return "", depth, false
	}
	return id.Name, depth, true
}

func renderSelector(e ast.Expr) string {
	switch v := e.(type) {
	case *ast.Ident:
		return v.Name
	case *ast.SelectorExpr:
		return renderSelector(v.X) + "." + v.Sel.Name
	case *ast.ParenExpr:
		return "(" + renderSelector(v.X) + ")"
	case *ast.BasicLit:
		return v.Value
	case *ast.CallExpr:
		// So a wrapped haystack reports the shape that was actually written.
		args := make([]string, 0, len(v.Args))
		for _, a := range v.Args {
			args = append(args, renderSelector(a))
		}
		return renderSelector(v.Fun) + "(" + strings.Join(args, ", ") + ")"
	default:
		return "<expr>"
	}
}

// guardScanRoots are the trees swept. internal/ and cmd/ are the whole Go
// surface of this repo (there are no root .go files).
var guardScanRoots = []string{"internal", "cmd"}

// manifestKnownHits are the hits this gate has READ AT THE SOURCE and cleared,
// spelled by SHAPE (hitShape) rather than by position, so moving the line does
// not silence the clearance and a second site of the same shape is not waived
// by accident. The list is checked in BOTH directions: an entry that stops
// appearing reds too, so a clearance cannot outlive the code it describes.
//
// It exists because widening the callee set to the whole matching family
// (task-0ab3dfa73662ee68) made the gate see one manifest-bound site the narrow
// three-name set never could:
//
//   - errors.go enumeratingSibling cuts cmd.Verb on "-" to find the verb's
//     FAMILY (`member-rm` → `member-ls`). The hyphen is the verb id's own
//     grammar — the same category as the "--flag=" parsing the negative
//     control clears — and the manifest declares no family field to read
//     instead. Read at the source 2026-09-20.
//
// Keep this list at the length of what has been read. It is NOT the escape
// hatch for a fresh hit: the remedy for one of those is to read the typed
// field.
var manifestKnownHits = []string{
	"strings.Cut(cmd.Verb) on manifest.Command",
}

// TestNoStringMatchStandsInForAManifestDeclaredFact is the live gate. Beyond
// the one read-and-cleared shape in manifestKnownHits the tree is at zero, so
// the next instance reds by itself.
//
// KNOWN BLIND SPOT, stated rather than papered over — and it is now ONE thing,
// not the head of a list. The detector is SYNTACTIC, so copying the field into
// a local first —
//
//	tmpl := cmd.HTTP.PathTemplate
//	if strings.Contains(tmpl, "/media") { … }
//
// defeats it, measured 2026-09-16 by doing exactly that to run.go and watching
// the gate stay green. Closing THAT needs go/types, which this module does not
// vendor (no golang.org/x/tools).
//
// The three escapes that used to sit alongside it are closed, not documented:
// a wrapped haystack (strings.Contains(strings.ToLower(cmd.X), …)), a matcher
// outside the original three names (strings.Index, strings.EqualFold), and the
// two combined were each purely syntactic and needed no go/types at all — they
// were an enumeration masquerading as a rule (task-0ab3dfa73662ee68). See
// TestManifestFactDetectorFiresThroughTheWholeMatchFamilyAndAWrappedHaystack,
// which pins all three.
//
// The gate is therefore a tripwire on the shape people actually write, not a
// proof of absence — the same bargain internal/apiclient/manifest_path_drift_
// test.go strikes. If a hit turns out to be legitimate, read the typed field or
// record its SHAPE above with what you read; do not launder it through a local.
func TestNoStringMatchStandsInForAManifestDeclaredFact(t *testing.T) {
	repo := repoRootForGuard(t)
	fset := token.NewFileSet()
	var all []manifestFactHit
	scanned := 0
	for _, r := range guardScanRoots {
		root := filepath.Join(repo, r)
		if _, err := os.Stat(root); err != nil {
			t.Fatalf("scan root %s missing: %v (the guard would pass vacuously)", root, err)
		}
		err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, p, nil, 0)
			if perr != nil {
				return nil // a file that does not parse is not this gate's business
			}
			scanned++
			for _, h := range scanManifestFactStringMatches(fset, f) {
				h.Pos = strings.TrimPrefix(h.Pos, repo+string(filepath.Separator))
				all = append(all, h)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("walk %s: %v", root, err)
		}
	}
	// A sweep that read nothing proves nothing.
	if scanned < 200 {
		t.Fatalf("scanned only %d non-test .go files under %v — the sweep did not reach the tree", scanned, guardScanRoots)
	}
	known := map[string]bool{}
	for _, k := range manifestKnownHits {
		known[k] = false
	}
	for _, h := range all {
		shape := hitShape(manifestQualifier, h)
		if _, isKnown := known[shape]; isKnown {
			known[shape] = true
			continue
		}
		t.Errorf("%s: strings.%s(%s, …) asks a rendered string a question %s.%s already answers with a typed field — read the declaration, not the spelling (task-ce8f04315a6d1f10)",
			h.Pos, h.Fn, h.Expr, manifestQualifier, h.Type)
	}
	// A clearance that no longer describes the tree is a stale reading, so it
	// reds instead of standing quietly.
	stale := []string{}
	for shape, seen := range known {
		if !seen {
			stale = append(stale, shape)
		}
	}
	sort.Strings(stale)
	if len(stale) > 0 {
		t.Errorf("manifestKnownHits entr(ies) %v no longer appear in the tree. Each was read at the source before it was "+
			"written down; the code it described has moved or changed, so drop the entry rather than leaving a clearance "+
			"standing over something nobody has read.", stale)
	}
}

// repoRootForGuard walks up from this package to the module root.
func repoRootForGuard(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatal("go.mod not found above internal/cli — the guard cannot locate the tree")
	return ""
}

// seedDefectSource is the pre-#14115 mediaUploadFileArg, reduced to the shape
// that matters. This is the POSITIVE CONTROL: a detector that does not fire
// here is not measuring anything.
const seedDefectSource = `package cli

import (
	"strings"

	"barkpark/internal/manifest"
)

func mediaUploadFileArg(cmd manifest.Command, args map[string]string) (string, bool) {
	if cmd.HTTP.Method != "POST" {
		return "", false
	}
	if !strings.Contains(cmd.HTTP.PathTemplate, "/media") {
		return "", false
	}
	for _, a := range cmd.Args {
		if v, ok := args[a.Name]; ok && v != "" {
			return v, true
		}
	}
	return "", false
}
`

func TestManifestFactDetectorFiresOnTheSeedDefect(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "seed.go", seedDefectSource, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	hits := scanManifestFactStringMatches(fset, f)
	if len(hits) != 1 {
		t.Fatalf("detector found %d hits in the seed defect, want exactly 1: %+v", len(hits), hits)
	}
	if hits[0].Expr != "cmd.HTTP.PathTemplate" || hits[0].Fn != "Contains" || hits[0].Type != "Command" {
		t.Fatalf("hit = %+v, want Contains on cmd.HTTP.PathTemplate bound to manifest.Command", hits[0])
	}
}

// seedDefectOnADeclaredArgType is the same class one field deeper: deciding
// from an arg's NAME spelling what its declared `Type` says outright. It binds
// through the range over cmd.Args, which no type annotation announces.
const seedDefectOnADeclaredArgType = `package cli

import (
	"strings"

	"barkpark/internal/manifest"
)

func looksLikeAFile(cmd manifest.Command) bool {
	for _, a := range cmd.Args {
		if strings.HasSuffix(a.Name, "_file") {
			return true
		}
	}
	return false
}
`

func TestManifestFactDetectorFiresThroughARangeBinding(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "argtype.go", seedDefectOnADeclaredArgType, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	hits := scanManifestFactStringMatches(fset, f)
	if len(hits) != 1 || hits[0].Expr != "a.Name" || hits[0].Type != "Arg" {
		t.Fatalf("hits = %+v, want exactly one HasSuffix on a.Name bound to manifest.Arg", hits)
	}
}

// legitimateStringWorkSource is the NEGATIVE CONTROL. Every call here is real
// code shape from this tree that must NOT be flagged:
//
//   - rawURL "?" — the cleared lookalike that asks whether a URL contains the
//     token it genuinely contains (run.go:1905, run.go:3746);
//   - cmd.ID == "media.upload" — the cleared lookalike that matches an EXACT
//     command id, i.e. reads the declaration rather than sniffing it;
//   - "--flag=" prefix parsing on a bare arg token, which IS the flag syntax;
//   - "+json" media-type suffix, where the suffix is the type's own grammar.
const legitimateStringWorkSource = `package cli

import (
	"strings"

	"barkpark/internal/manifest"
)

func legit(cmd manifest.Command, rawURL, a, mediaType string) bool {
	if strings.Contains(rawURL, "?") {
		return true
	}
	if cmd.ID == "media.upload" {
		return true
	}
	if strings.HasPrefix(a, "--dataset=") {
		return true
	}
	if strings.HasSuffix(mediaType, "+json") {
		return true
	}
	return false
}
`

func TestManifestFactDetectorStaysQuietOnLegitimateStringWork(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "legit.go", legitimateStringWorkSource, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if hits := scanManifestFactStringMatches(fset, f); len(hits) != 0 {
		t.Fatalf("detector fired on legitimate string work: %+v", hits)
	}
}

// escapedFactShapes is the RED CONTROL for the widening: the three shapes that
// were measured PASSING this gate on 2026-09-18 (task-0ab3dfa73662ee68) while
// being the same defect as the seed — a rendered manifest string asked a
// question the struct already answers.
//
//  1. the haystack wrapped in a call, so arg 0 is a CallExpr and the old
//     selector-only walk gave up;
//  2. strings.Index, outside the old three-name callee set;
//  3. strings.EqualFold, likewise.
//
// A synthetic fixture cannot prove the LIVE gate sees them — only the tree
// sweep does that, and the row's probes did, at run.go — but it does keep the
// predicate from silently narrowing back.
const escapedFactShapes = `package cli

import (
	"strings"

	"barkpark/internal/manifest"
)

func wrapped(cmd manifest.Command) bool {
	return strings.Contains(strings.ToLower(cmd.HTTP.PathTemplate), "/media")
}

func indexed(cmd manifest.Command) bool {
	return strings.Index(cmd.HTTP.PathTemplate, "/media") >= 0
}

func folded(cmd manifest.Command) bool {
	return strings.EqualFold(cmd.HTTP.Method, "POST")
}
`

func TestManifestFactDetectorFiresThroughTheWholeMatchFamilyAndAWrappedHaystack(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "escapes.go", escapedFactShapes, 0)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	got := map[string]bool{}
	for _, h := range scanManifestFactStringMatches(fset, f) {
		if h.Type != "Command" {
			t.Errorf("hit %+v is not bound to manifest.Command", h)
		}
		got[h.Fn+"("+h.Expr+")"] = true
	}
	for _, want := range []string{
		"Contains(strings.ToLower(cmd.HTTP.PathTemplate))",
		"Index(cmd.HTTP.PathTemplate)",
		"EqualFold(cmd.HTTP.Method)",
	} {
		if !got[want] {
			t.Errorf("escape %s was NOT reported — the detector has narrowed back to an enumeration. Hits: %v", want, got)
		}
	}
}

// TestStringMatchFamilyExcludesTheTransformingHalf holds the other side: the
// family is a rule, and a rule that said yes to everything in the strings
// package would make this gate a ban on the package rather than a detector.
func TestStringMatchFamilyExcludesTheTransformingHalf(t *testing.T) {
	for _, name := range []string{"Contains", "ContainsAny", "HasPrefix", "HasSuffix",
		"Index", "IndexByte", "LastIndex", "EqualFold", "Count", "Cut", "CutPrefix", "SplitN"} {
		if !isStringMatchFamily(name) {
			t.Errorf("strings.%s asks a question of its first argument but is not in the family", name)
		}
	}
	for _, name := range []string{"ToLower", "ToUpper", "TrimSpace", "TrimPrefix", "TrimSuffix",
		"Replace", "ReplaceAll", "Join", "Fields", "Title", "Repeat", "NewReplacer"} {
		if isStringMatchFamily(name) {
			t.Errorf("strings.%s only PRODUCES a string — flagging it makes the gate a ban on the package, not a detector", name)
		}
	}
}

// ── The reachability floor (task-0f89f5ac08cf44b6) ──────────────────────────
//
// TestNoStringMatchStandsInForAManifestDeclaredFact carries a VACUITY floor —
// it fails if it scanned fewer than 200 non-test files. That floor measures
// that the walk reached the tree. It does NOT measure that the detector can
// still SEE anything in it, and those are different facts.
//
// Measured 2026-09-16, the gap is real: setting manifestQualifier to a package
// name nothing imports makes a tree-wide hit IMPOSSIBLE, and the live gate
// above still reports `ok` — 423 files scanned, floor satisfied, zero hits, a
// green with no subject. The three synthetic controls DO catch that particular
// mutation, but only because each parses a source string that literally spells
// `manifest.Command`; they would go on passing against a tree that had aliased
// its import (`mf "…/internal/manifest"`), renamed the package, or stopped
// importing it, because they never read the tree at all.
//
// So this test asserts the one thing no synthetic fixture can: that on the
// REAL tree, right now, the binding half still binds. If this reds while the
// gate above stays green, the gate's zero has stopped meaning "no instances"
// and started meaning "no subjects".
//
// Floors are set well under today's measurement — 133 bindings across 61 of
// 424 non-test files, printed by this test's t.Log so the next reader sees the
// live number rather than this comment's — so ordinary refactoring does not
// trip them; they catch a COLLAPSE, not drift. (The floors were first drafted
// at 150 bindings from a grep of textual `manifest.` occurrences, which counts
// a different quantity — call sites and type literals as well as bindings —
// and this test promptly failed on its own author. The number in a floor must
// come from the thing the floor measures.)
func TestManifestFactDetectorReachesTheRealTree(t *testing.T) {
	repo := repoRootForGuard(t)
	fset := token.NewFileSet()
	bindingFiles, bindings := 0, 0
	scanned := 0
	for _, r := range guardScanRoots {
		root := filepath.Join(repo, r)
		if _, err := os.Stat(root); err != nil {
			t.Fatalf("scan root %s missing: %v", root, err)
		}
		if err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, p, nil, 0)
			if perr != nil {
				return nil
			}
			scanned++
			if n := len(bindManifestIdents(f)); n > 0 {
				bindingFiles++
				bindings += n
			}
			return nil
		}); err != nil {
			t.Fatalf("walk %s: %v", root, err)
		}
	}
	if scanned < 200 {
		t.Fatalf("scanned only %d non-test .go files — the walk did not reach the tree", scanned)
	}
	const (
		minBindingFiles = 30
		minBindings     = 60
	)
	if bindingFiles < minBindingFiles || bindings < minBindings {
		t.Fatalf("the detector binds %d identifier(s) across %d file(s) of %d scanned (floors: %d files, %d bindings).\n"+
			"Nothing in the tree is bound to a %s.* type any more, so TestNoStringMatchStandsInForAManifestDeclaredFact "+
			"cannot report a hit and its green says nothing. Either the manifest import was aliased/renamed (teach "+
			"bindManifestIdents the new spelling) or the consumers genuinely moved (re-point guardScanRoots) — do not "+
			"lower these floors to restore the green.",
			bindings, bindingFiles, scanned, minBindingFiles, minBindings, manifestQualifier)
	}
	t.Logf("reachability: %d bindings across %d/%d non-test files", bindings, bindingFiles, scanned)
}

// ── The unswept-lane sweep record (task-0f89f5ac08cf44b6) ───────────────────
//
// The parent row (task-ce8f04315a6d1f10) required six disjoint Go-tree lanes to
// state which files they swept "so absence is distinguishable from coverage".
// Two lanes left no branch, no PR and no child row, so for their areas the
// tree's silence was uninterpretable. Those areas were re-swept by hand on
// 2026-09-16 at c74b28975 — every non-test strings.Contains/HasPrefix/HasSuffix
// occurrence read, and every one found to be legitimate text-grammar parsing
// (mermaid and diff syntax, the scaffy DSL, hcloud's INI-ish context file,
// docker tag prefixes) or already the FIXED side of a shipped lane
// (scaffy/apply.go reads o.Mark.Name, the declared fact, exactly as #14304
// landed it). Verdict: swept, clean, no findings.
//
// The reason that sweep is CHEAP to trust — and the reason this record is a
// test rather than a comment — is that none of these packages imports
// internal/manifest, so the manifest sub-shape cannot occur in them at all.
// That is what makes their hand-sweep final. The moment one of them does import
// it, the hand-sweep's premise is gone and the record above is stale: this test
// reds and says so, instead of the note quietly rotting in a comment.
//
// (The AST gate itself DOES reach these packages — planting the seed defect in
// internal/pdrender on 2026-09-16 made TestNoStringMatchStandsInForAManifest-
// DeclaredFact fail on it, which is the control proving their zero is a real
// reading and not an unvisited directory.)
func TestReSweptLanesStillHoldNoManifestConsumer(t *testing.T) {
	repo := repoRootForGuard(t)
	// The six areas no merged lane PR touched, by elimination from #14115,
	// #14297, #14300, #14304, #14305, #14306.
	reswept := []string{"pdrender", "scaffy", "builder", "runtime", "hetzner", "provisioner"}
	fset := token.NewFileSet()
	for _, pkg := range reswept {
		root := filepath.Join(repo, "internal", pkg)
		if _, err := os.Stat(root); err != nil {
			t.Errorf("re-swept area internal/%s is gone: %v — the sweep record no longer describes the tree", pkg, err)
			continue
		}
		files := 0
		if err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
				return nil
			}
			f, perr := parser.ParseFile(fset, p, nil, 0)
			if perr != nil {
				return nil
			}
			files++
			if n := len(bindManifestIdents(f)); n > 0 {
				rel := strings.TrimPrefix(p, repo+string(filepath.Separator))
				t.Errorf("%s now binds %d %s.* value(s). internal/%s was hand-swept on 2026-09-16 and cleared on the "+
					"premise that it consumes no manifest type; that premise no longer holds, so re-read its "+
					"strings.Contains/HasPrefix/HasSuffix sites against the declarations before trusting the record above.",
					rel, n, manifestQualifier, pkg)
			}
			return nil
		}); err != nil {
			t.Errorf("walk internal/%s: %v", pkg, err)
		}
		if files == 0 {
			t.Errorf("internal/%s held no non-test .go files — this area's check ran vacuously", pkg)
		}
	}
}
