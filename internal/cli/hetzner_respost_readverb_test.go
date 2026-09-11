package cli

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// hzNotReadableKinds DERIVES, from this package's own source, the set of `kind`
// strings that can reach hzResNotReadable. Both entry points that can land in
// that branch — hzResObserved (its post-read came back nil) and
// hzResObservedResponse (the create response carried no object) — take the kind
// as a string literal at a fixed argument position, so the call sites ARE the
// enumeration. A new mutation verb with a new kind therefore shows up here
// without anybody remembering to add it to a list: an enumeration written by
// hand goes stale the day a verb is added, a derivation cannot.
func hzNotReadableKinds(t *testing.T) []string {
	t.Helper()
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parse package source: %v", err)
	}
	// argument index of `kind` per entry point
	kindArg := map[string]int{"hzResObserved": 3, "hzResObservedResponse": 2}
	seen := map[string]bool{}
	for _, pkg := range pkgs {
		for _, file := range pkg.Files {
			ast.Inspect(file, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				id, ok := call.Fun.(*ast.Ident)
				if !ok {
					return true
				}
				idx, ok := kindArg[id.Name]
				if !ok || idx >= len(call.Args) {
					return true
				}
				lit, ok := call.Args[idx].(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					t.Errorf("%s: kind argument is not a string literal — the enumeration cannot see it",
						fset.Position(call.Pos()))
					return true
				}
				kind, err := strconv.Unquote(lit.Value)
				if err != nil {
					t.Fatalf("unquote kind literal: %v", err)
				}
				seen[kind] = true
				return true
			})
		}
	}
	kinds := make([]string, 0, len(seen))
	for k := range seen {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	if len(kinds) < 5 {
		t.Fatalf("derived only %d kinds (%v) — the AST scan found nothing, so every assertion below is vacuous",
			len(kinds), kinds)
	}
	return kinds
}

// hzCommandResolves drives the REAL command tree with the given `bp cloud …`
// token path and reports whether the dispatcher recognised it. Every hetzner
// dispatcher answers an unrecognised token with `unknown … %q`, and every
// recognised verb answers a bare invocation with a missing-argument usage error
// LONG before it builds a client, so this probe resolves the verb without
// touching the network.
func hzCommandResolves(t *testing.T, tokens []string) (bool, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{}
	w.applyGlobals(g)
	// `bp cloud …` is the operator-facing spelling; runCloud is handed
	// everything AFTER the `cloud` noun, so the probe drops it.
	args := tokens
	if len(args) > 0 && args[0] == "cloud" {
		args = args[1:]
	}
	runCloud(w, g, args)
	said := stdout.String() + stderr.String()
	return !strings.Contains(said, "unknown"), said
}

// hzHintCommandPath pulls the backticked command out of a receipt and truncates
// it at its verb (`get`), which is the part the dispatcher resolves; the
// trailing id/flag placeholders are the operator's to fill in.
func hzHintCommandPath(msg string) ([]string, bool) {
	start := strings.Index(msg, "`bp ")
	if start < 0 {
		return nil, false
	}
	rest := msg[start+1:]
	end := strings.Index(rest, "`")
	if end < 0 {
		return nil, false
	}
	fields := strings.Fields(rest[:end])
	if len(fields) < 2 || fields[0] != "bp" {
		return nil, false
	}
	for i, f := range fields {
		if f == "get" {
			return fields[1 : i+1], true
		}
	}
	return nil, false
}

// TestHzResNotReadableHintNamesRealVerb is THE DETECTOR (PDS-D447 finding 3).
//
// hzResNotReadable's receipt tells an operator to re-read the resource with a
// named command. That sentence is a CLAIM ABOUT THIS CLI, and until this test
// existed nothing checked it: the hint was built by interpolating the kind into
// `bp cloud hetzner <kind> get <name>`, which is a real command for the kinds
// that happen to sit directly under `hetzner` and a dead end for every kind
// that sits under a GROUP (`dns`, `storage`) or has no read verb at all.
//
// The assertion: for every kind that can reach the branch, either the receipt
// names a command the dispatcher actually resolves, or it says plainly that no
// such verb exists. Naming one that does not resolve is the failure.
func TestHzResNotReadableHintNamesRealVerb(t *testing.T) {
	for _, kind := range hzNotReadableKinds(t) {
		t.Run(kind, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			w := newWriter(&stdout, &stderr)
			g := globals{}
			w.applyGlobals(g)
			hzResNotReadable(w, "create", kind, 42, "probe-name")
			msg := stdout.String() + stderr.String()
			if !strings.Contains(msg, "NOT READABLE") {
				t.Fatalf("receipt for kind %q is not the not-readable refusal: %s", kind, msg)
			}
			tokens, ok := hzHintCommandPath(msg)
			if !ok {
				// No command named at all. That is only honest if the receipt
				// SAYS there is none.
				if !strings.Contains(msg, "no ") {
					t.Fatalf("kind %q names no command and does not say why: %s", kind, msg)
				}
				return
			}
			resolves, said := hzCommandResolves(t, tokens)
			if !resolves {
				t.Errorf("kind %q: the receipt tells the operator to run `bp %s …`, but the CLI answers %q — "+
					"the remediation names a verb that does not exist", kind, strings.Join(tokens, " "), strings.TrimSpace(said))
			}
		})
	}
}

// TestHzCommandResolvesDiscriminates is the CONTROL for the probe above. A probe
// that answered "resolves" for everything would make the detector vacuous, so
// this pins both directions on commands whose status is not in question.
func TestHzCommandResolvesDiscriminates(t *testing.T) {
	if ok, said := hzCommandResolves(t, []string{"hetzner", "volume", "get"}); !ok {
		t.Errorf("`bp cloud hetzner volume get` should resolve, probe said no: %q", said)
	}
	if ok, said := hzCommandResolves(t, []string{"hetzner", "record", "get"}); ok {
		t.Errorf("`bp cloud hetzner record get` is not a command; probe said it resolves: %q", said)
	}
	if ok, said := hzCommandResolves(t, []string{"hetzner", "zone", "get"}); ok {
		t.Errorf("`bp cloud hetzner zone get` is not a command; probe said it resolves: %q", said)
	}
}

