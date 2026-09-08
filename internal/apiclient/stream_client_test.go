package apiclient

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// streamClient() must carry the shared transport. Without it a long-lived read
// silently loses BOTH the 429 backpressure wait and the transient-500 retry —
// not by anyone's decision, but as a side effect of needing Timeout: 0.
func TestStreamClientCarriesTheRetryTransport(t *testing.T) {
	c := streamClient()
	if c.Timeout != 0 {
		t.Errorf("Timeout = %v, want 0 — these paths are long-lived and ctx ends them", c.Timeout)
	}
	if c.Transport == nil {
		t.Fatal("Transport is nil — a bare client uses http.DefaultTransport, so " +
			"retryTransport is not in the chain and the policy is silently absent")
	}
	if _, ok := c.Transport.(*retryTransport); !ok {
		t.Errorf("Transport is %T, want *retryTransport", c.Transport)
	}
}

// THE ARM THAT OUTLIVES THIS FIX. The five sites were not wrong by intent —
// each needed `Timeout: 0` and built a bare client to get it, dropping the
// transport as a SIDE EFFECT. Nothing stopped a sixth from doing the same, and
// a grep for the policy's ABSENCE cannot find these: there is nothing to find,
// only something missing.
//
// So this asserts the property structurally over the package's own source: no
// non-test file may construct an http.Client with a nil Transport. New() is the
// one legitimate constructor and it sets Transport explicitly; streamClient()
// is the other. A sixth stream added later fails HERE rather than in production.
func TestNoBareHTTPClientConstructionInPackage(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	var offenders []string
	scanned, composites := 0, 0

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		scanned++

		ast.Inspect(f, func(n ast.Node) bool {
			lit, ok := n.(*ast.CompositeLit)
			if !ok {
				return true
			}
			// Match `http.Client{…}` specifically, not every composite.
			sel, ok := lit.Type.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "Client" {
				return true
			}
			pkg, ok := sel.X.(*ast.Ident)
			if !ok || pkg.Name != "http" {
				return true
			}
			composites++
			for _, elt := range lit.Elts {
				kv, ok := elt.(*ast.KeyValueExpr)
				if !ok {
					continue
				}
				if k, ok := kv.Key.(*ast.Ident); ok && k.Name == "Transport" {
					return true // explicitly sets Transport — fine
				}
			}
			offenders = append(offenders,
				filepath.Join(name, fset.Position(lit.Pos()).String()))
			return true
		})
	}

	// NON-VACUITY, both halves. A scan that parsed nothing, or that never found
	// an http.Client composite at all, would report a clean package while being
	// blind — which is the same shape of defect as the one under test.
	if scanned < 5 {
		t.Fatalf("control failed: only %d non-test .go files scanned; the scan is "+
			"not seeing the package", scanned)
	}
	if composites == 0 {
		t.Fatal("control failed: found ZERO http.Client composite literals. New() " +
			"and streamClient() both build one, so the matcher is broken and any " +
			"'clean' verdict below is meaningless")
	}

	if len(offenders) > 0 {
		t.Errorf("http.Client constructed with no Transport at %v.\n"+
			"A bare client uses http.DefaultTransport, so retryTransport is not in "+
			"its chain: the 429 backoff and the transient-500 retry are silently "+
			"absent. Long-lived reads use streamClient(); everything else goes "+
			"through the Client built by New().", offenders)
	}
}

// The transport must actually be reachable as a RoundTripper — a compile-time
// check that streamClient's value satisfies the interface the policy rides on.
var _ http.RoundTripper = (*retryTransport)(nil)
