package chathost

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// No test in this package writes a package-level variable. A turn or lease
// goroutine one test leaves running reads its settings after the test returned,
// so a test that shortens a shared setting races it under -race, about 1 run in
// 8 for terminalPublishTimeout (task-522b05a5c537bebd). The race detector sees
// that only when the leftover goroutine happens to read at the wrong moment;
// this check sees the write every time. A test shortens a setting on its own
// Runner, LocalHandler or ClaudeStatusLabeler instead.
func TestNoTestWritesAPackageLevelVariable(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	parsed := map[string]*ast.File{}
	globals := map[string]bool{}
	specs := map[*ast.ValueSpec]bool{}
	for _, name := range files {
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		parsed[name] = file
		for _, decl := range file.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.VAR {
				continue
			}
			for _, spec := range gen.Specs {
				value := spec.(*ast.ValueSpec)
				specs[value] = true
				for _, ident := range value.Names {
					if ident.Name != "_" { // var _ Iface = … is a compile-time check, not a variable
						globals[ident.Name] = true
					}
				}
			}
		}
	}

	// A scan that saw no package-level vars would pass on any tree.
	if _, err := os.Stat("runner.go"); err != nil || !globals["ErrRevoked"] || !globals["turnFilesFolder"] {
		t.Fatalf("the scan did not see this package's sources (%d files, %d vars): %v", len(parsed), len(globals), err)
	}

	// isGlobal: ident names a package-level var, not a local that shadows one.
	// Per-file resolution leaves a name declared in another file unresolved.
	isGlobal := func(ident *ast.Ident) bool {
		if !globals[ident.Name] {
			return false
		}
		if ident.Obj == nil {
			return true
		}
		spec, ok := ident.Obj.Decl.(*ast.ValueSpec)
		return ok && specs[spec]
	}
	var writes []string
	written := func(expr ast.Expr) {
		// The root of x, x.f, x[i], *x, (x).
		for {
			switch e := expr.(type) {
			case *ast.SelectorExpr:
				expr = e.X
				continue
			case *ast.IndexExpr:
				expr = e.X
				continue
			case *ast.StarExpr:
				expr = e.X
				continue
			case *ast.ParenExpr:
				expr = e.X
				continue
			case *ast.Ident:
				if isGlobal(e) {
					writes = append(writes, fset.Position(e.Pos()).String()+": "+e.Name)
				}
			}
			return
		}
	}
	for name, file := range parsed {
		if !strings.HasSuffix(name, "_test.go") {
			continue
		}
		ast.Inspect(file, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.AssignStmt:
				if n.Tok == token.DEFINE {
					return true
				}
				for _, lhs := range n.Lhs {
					written(lhs)
				}
			case *ast.IncDecStmt:
				written(n.X)
			case *ast.UnaryExpr:
				// &global hands the variable to code that may write it.
				if n.Op == token.AND {
					written(n.X)
				}
			}
			return true
		})
	}
	if len(writes) > 0 {
		t.Fatalf("tests write package-level variables; set the value on the test's own instance instead:\n%s", strings.Join(writes, "\n"))
	}
}
