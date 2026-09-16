package cli

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
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
//	a strings.Contains / HasPrefix / HasSuffix whose HAYSTACK is a field
//	reached off a value of a manifest.* type — i.e. code asking a rendered
//	string a question that the same struct already answers with a typed field.
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
//	run.go:1429:6: Contains(cmd.HTTP.PathTemplate, …) [cmd is manifest.Command]
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
	Fn   string // Contains | HasPrefix | HasSuffix
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
		if !ok || x.Name != manifestQualifier {
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
		switch fn.Sel.Name {
		case "Contains", "HasPrefix", "HasSuffix":
		default:
			return true
		}
		root, depth, ok := selectorRoot(c.Args[0])
		if !ok || depth == 0 {
			// depth 0 means the haystack is a bare identifier (a line, a
			// rawURL, a flag token) — free text, not a declared field.
			return true
		}
		typ, ok := bound[root]
		if !ok {
			return true
		}
		hits = append(hits, manifestFactHit{
			Pos:  fset.Position(c.Pos()).String(),
			Fn:   fn.Sel.Name,
			Expr: renderSelector(c.Args[0]),
			Root: root,
			Type: typ,
		})
		return true
	})
	return hits
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
	default:
		return "<expr>"
	}
}

// guardScanRoots are the trees swept. internal/ and cmd/ are the whole Go
// surface of this repo (there are no root .go files).
var guardScanRoots = []string{"internal", "cmd"}

// TestNoStringMatchStandsInForAManifestDeclaredFact is the live gate. It
// carries NO waiver list: the tree is at zero today (403 non-test
// strings.Contains/HasPrefix/HasSuffix lines across internal/ and cmd/, none
// of them of this shape), so the next instance reds by itself.
//
// KNOWN BLIND SPOT, stated rather than papered over: the detector is
// SYNTACTIC. Copying the field into a local first —
//
//	tmpl := cmd.HTTP.PathTemplate
//	if strings.Contains(tmpl, "/media") { … }
//
// defeats it, measured 2026-09-16 by doing exactly that to run.go and watching
// the gate stay green. Closing that needs go/types, which this module does not
// vendor (no golang.org/x/tools). The gate is therefore a tripwire on the
// shape people actually write, not a proof of absence — the same bargain
// internal/apiclient/manifest_path_drift_test.go strikes. If a hit ever turns
// out to be legitimate, read the typed field or say in a comment why the
// spelling IS the fact — do not append a line to a table here, and do not
// launder it through a local.
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
	for _, h := range all {
		t.Errorf("%s: strings.%s(%s, …) asks a rendered string a question %s.%s already answers with a typed field — read the declaration, not the spelling (task-ce8f04315a6d1f10)",
			h.Pos, h.Fn, h.Expr, manifestQualifier, h.Type)
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
