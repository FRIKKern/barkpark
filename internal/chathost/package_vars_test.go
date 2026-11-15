package chathost

import (
	"go/ast"
	"go/build"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
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
//
// The package is type-checked, so a name resolves as the compiler resolves it
// (a local that shadows a global is not the global). A test write is any of:
// an assignment or ++/-- whose target is rooted at a package-level var (x,
// x.f, x[i], *x); &x; a method with a pointer receiver called on x or reached
// through it (x.Store(...), x.f.Reset()); copy, clear or delete into x. It does
// not follow x passed to a function that writes through it.
func TestNoTestWritesAPackageLevelVariable(t *testing.T) {
	all, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	fset := token.NewFileSet()
	var names []string
	var files []*ast.File
	for _, name := range all {
		// The files this build compiles: turn_files_unix.go or _other.go.
		if match, err := build.Default.MatchFile(".", name); err != nil || !match {
			continue
		}
		names = append(names, name)
		file, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, file)
	}
	info := &types.Info{Uses: map[*ast.Ident]types.Object{}, Selections: map[*ast.SelectorExpr]*types.Selection{}}
	config := types.Config{Importer: importer.Default()}
	pkg, err := config.Check("chathost", fset, files, info)
	if err != nil {
		t.Fatalf("type-checking the package for the scan: %v", err)
	}
	// A scan that saw no package-level vars would pass on any tree.
	for _, want := range []string{"ErrRevoked", "turnFilesFolder"} {
		if _, ok := pkg.Scope().Lookup(want).(*types.Var); !ok {
			t.Fatalf("the scan did not see %s: it is not reading this package's sources (%d files)", want, len(files))
		}
	}

	// global: the package-level var expr is rooted at, if any.
	global := func(expr ast.Expr) *types.Var {
		for {
			switch e := expr.(type) {
			case *ast.SelectorExpr:
				expr = e.X
			case *ast.IndexExpr:
				expr = e.X
			case *ast.StarExpr:
				expr = e.X
			case *ast.ParenExpr:
				expr = e.X
			case *ast.Ident:
				v, ok := info.Uses[e].(*types.Var)
				if ok && v.Parent() == pkg.Scope() {
					return v
				}
				return nil
			default:
				return nil
			}
		}
	}
	var writes []string
	flag := func(at ast.Node, how string, expr ast.Expr) {
		if v := global(expr); v != nil {
			writes = append(writes, fset.Position(at.Pos()).String()+": "+how+" "+v.Name())
		}
	}
	for i, file := range files {
		if !strings.HasSuffix(names[i], "_test.go") {
			continue
		}
		ast.Inspect(file, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.AssignStmt:
				if n.Tok != token.DEFINE {
					for _, lhs := range n.Lhs {
						flag(lhs, "assigns", lhs)
					}
				}
			case *ast.IncDecStmt:
				flag(n, "increments", n.X)
			case *ast.UnaryExpr:
				if n.Op == token.AND {
					flag(n, "takes the address of", n.X)
				}
			case *ast.SelectorExpr:
				selection := info.Selections[n]
				if selection == nil || selection.Kind() == types.FieldVal {
					break
				}
				if signature, ok := selection.Obj().Type().(*types.Signature); ok && signature.Recv() != nil {
					if _, pointer := signature.Recv().Type().(*types.Pointer); pointer {
						flag(n, "calls pointer method "+n.Sel.Name+" on", n.X)
					}
				}
			case *ast.CallExpr:
				if ident, ok := n.Fun.(*ast.Ident); ok && len(n.Args) > 0 {
					if builtin, ok := info.Uses[ident].(*types.Builtin); ok {
						switch builtin.Name() {
						case "copy", "clear", "delete":
							flag(n, builtin.Name()+" into", n.Args[0])
						}
					}
				}
			}
			return true
		})
	}
	if len(writes) > 0 {
		t.Fatalf("tests write package-level variables; set the value on the test's own instance instead:\n%s", strings.Join(writes, "\n"))
	}
}
