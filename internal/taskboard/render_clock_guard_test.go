package taskboard

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// wallClockFamily is the set of time package entry points that READ the machine
// clock. Membership is decided by one question: can a renderer reach this and
// get an answer that changes between two runs of the same golden?
//
//   - Now/Since/Until read the current instant (Since(t) IS time.Now().Sub(t),
//     and it is the first call a renderer computing "2d ago" reaches for).
//   - After/Tick/NewTimer/NewTicker/AfterFunc arm the clock to fire later. The
//     object forms are in because otherwise the rule is defeatable by a
//     one-word rewrite: time.After(d) becomes time.NewTimer(d).C and the guard
//     goes quiet on identical behaviour.
//
// Deliberately OUT: Parse, ParseDuration, Date, Unix, Duration and the format
// constants. Those build or print an instant supplied as DATA — they are what a
// correct renderer uses on the `now` its caller handed it, so putting them in
// would red the very idiom this test exists to protect.
var wallClockFamily = map[string]bool{
	"Now":       true,
	"Since":     true,
	"Until":     true,
	"After":     true,
	"Tick":      true,
	"NewTimer":  true,
	"NewTicker": true,
	"AfterFunc": true,
}

// wallClockHits reports every wall-clock reference in one Go source, as
// "time.Now"-style spellings in source order.
//
// It walks the AST rather than matching text, for two reasons the regex it
// replaced got wrong in both directions. A text match MISSES the bare function
// value `var clock = time.Now` (no parens — the standard injectable-clock
// idiom, and the shape program.go actually uses), and it FIRES on prose: both
// merge.go and motion.go carry doc comments containing the literal words
// "time.Now", so a widened regex would red two files that never call it.
func wallClockHits(filename string, src []byte) ([]string, error) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, filename, src, 0)
	if err != nil {
		return nil, err
	}
	var hits []string
	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		pkg, ok := sel.X.(*ast.Ident)
		if !ok || pkg.Name != "time" || !wallClockFamily[sel.Sel.Name] {
			return true
		}
		hits = append(hits, "time."+sel.Sel.Name)
		return true
	})
	return hits, nil
}

// TestRenderPathTakesItsClockFromTheCaller pins the property that makes every
// taskboard golden time-independent BY CONSTRUCTION rather than by luck: no
// rendering code in this package reads the wall clock. RenderTaskDetail and
// friends take `now time.Time` from the caller, and the goldens pass a fixed
// instant (detailNow, 2026-07-04T17:30Z). That is why a golden written months
// ago still renders "created 2d ago (Jul 02, 09:12)" today instead of decaying
// into "2mo ago" and going red every morning.
//
// A single wall-clock read slipped onto the render path silently converts every
// golden in this package into a one-day-shelf-life fixture, and the resulting
// red looks exactly like an ordinary golden drift — so it gets "fixed" by
// regeneration, which buys one more day. This test is the thing that says the
// cause out loud instead.
//
// The rule is a predicate, not a snapshot: a wall-clock read is allowed only in
// a file that OWNS a clock (it is a data-fetch or a timing site, not a
// renderer), and the ratchet runs in both directions — an owner that no longer
// reads the clock is also an error, so the allowance can never silently widen
// past what it was granted for.
//
// The predicate is over the wall-clock FAMILY (wallClockFamily), not over one
// spelling. It used to be `regexp.MustCompile("\\btime\\.Now\\(\\)")`, which
// stated "no rendering code reads the wall clock" and enforced "no rendering
// code types those eleven characters": time.Since, time.After and the bare
// `time.Now` function value all walked past it, and fetch.go's retry sleep was
// living outside the ratchet in plain sight.
func TestRenderPathTakesItsClockFromTheCaller(t *testing.T) {
	// clockOwners are the non-rendering sites permitted to read the wall clock,
	// each with the reason the allowance exists. Nothing else in the package may.
	clockOwners := map[string]string{
		"detail_data.go": "snapshot assembly stamps the fetch instant it then PASSES to renderers",
		"events.go":      "measures elapsed time for the event-poll backoff; renders nothing",
		"wirelog.go":     "timestamps each wire read for the byte counter; renders nothing and is off unless BARKPARK_TASKBOARD_WIRELOG is set",
		"clock.go":       "THE seam: the one binding of the real clock into Model.now, which every renderer then takes as a parameter. The file exists so this allowance covers a binding and nothing else",
		"fetch.go":       "sleeps a retry backoff between snapshot attempts (time.After on a relative Duration). It is the IO boundary — it reads no instant, formats nothing and hands no time to a renderer",
	}

	// POSITIVE CONTROL, one arm per family member. An empty scan must not be
	// readable as a pass: prove the scanner fires on each shape it is hunting,
	// in the exact source form the escape would take, before trusting a zero.
	for _, arm := range []struct{ name, src string }{
		{"time.Now", "func f() { now := time.Now().UTC(); _ = now }"},
		{"time.Now as a value", "var clock = time.Now"},
		{"time.Since", "func f(t time.Time) time.Duration { return time.Since(t) }"},
		{"time.Until", "func f(t time.Time) time.Duration { return time.Until(t) }"},
		{"time.After", "func f(d time.Duration) { <-time.After(d) }"},
		{"time.Tick", "func f(d time.Duration) { <-time.Tick(d) }"},
		{"time.NewTimer", "func f(d time.Duration) { <-time.NewTimer(d).C }"},
		{"time.NewTicker", "func f(d time.Duration) { <-time.NewTicker(d).C }"},
		{"time.AfterFunc", "func f(d time.Duration) { time.AfterFunc(d, func() {}) }"},
	} {
		hits := controlHits(t, arm.src)
		if len(hits) == 0 {
			t.Fatalf("scanner does not match %s (%q) — every verdict below would be vacuous for that spelling", arm.name, arm.src)
		}
	}

	// NEGATIVE CONTROL. The other half of the same claim: a scanner that reds on
	// correct code buys its coverage by making the rule unusable, and the
	// idioms below are precisely what a correct renderer is SUPPOSED to write.
	for _, arm := range []struct{ name, src string }{
		{"an injected clock call", "func f(clock func() time.Time) { now := clock(); _ = now }"},
		{"a clock taken from the model", "func (m Model) f() { now := m.now(); _ = now }"},
		{"a caller-supplied instant", "func f(now time.Time) string { return now.UTC().Format(time.RFC3339) }"},
		{"formatting data, not the clock", "func f(s string) (time.Time, error) { return time.Parse(time.RFC3339, s) }"},
		{"a doc comment naming the clock", "// no time.Now here, and no time.Since either\nfunc f() {}"},
		{"the words in a string literal", "func f() string { return \"time.Now()\" }"},
	} {
		if hits := controlHits(t, arm.src); len(hits) > 0 {
			t.Fatalf("scanner matches %s (%q) as %v — it would red on correct code", arm.name, arm.src, hits)
		}
	}

	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read package dir: %v", err)
	}

	found := map[string][]string{}
	scanned := 0
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src, err := os.ReadFile(filepath.Clean(name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		scanned++
		hits, err := wallClockHits(name, src)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		if len(hits) > 0 {
			found[name] = hits
		}
	}

	// A scan that reached no files would report a clean render path having
	// measured nothing at all.
	if scanned == 0 {
		t.Fatal("scanned 0 non-test .go files in internal/taskboard — the scan measured nothing")
	}

	names := make([]string, 0, len(found))
	for name := range found {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		if _, ok := clockOwners[name]; !ok {
			t.Errorf("%s reads the wall clock %d time(s): %s. "+
				"Rendering code must take `now time.Time` from its caller — a wall-clock read here "+
				"makes every golden in this package expire the day after it is written. "+
				"If this file genuinely owns a clock (data fetch or timing, not rendering), "+
				"add it to clockOwners in %s with the reason.",
				name, len(found[name]), strings.Join(found[name], ", "), "render_clock_guard_test.go")
		}
	}

	// The other direction: a granted allowance that is no longer used must be
	// surrendered, or it sits there ready to cover a future renderer.
	for name, why := range clockOwners {
		if len(found[name]) == 0 {
			t.Errorf("clockOwners grants %s a wall-clock read (%q) but it no longer reads the clock — "+
				"remove the entry rather than leaving a widened allowance behind", name, why)
		}
	}
}

// controlHits runs the scanner over a fragment, wrapped into the smallest legal
// file. The controls go through the SAME function as the package scan; a
// control that took a different path would be testing a different scanner.
func controlHits(t *testing.T, fragment string) []string {
	t.Helper()
	src := fmt.Sprintf("package p\n\nimport \"time\"\n\ntype Model struct{ now func() time.Time }\n\n%s\n", fragment)
	hits, err := wallClockHits("control.go", []byte(src))
	if err != nil {
		t.Fatalf("control fragment does not parse (%q): %v", fragment, err)
	}
	return hits
}
