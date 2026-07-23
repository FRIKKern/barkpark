package scaffy

// JS-assert order guard (charter D96). A fresh-worktree ASSERT CMD that
// reads or executes the pnpm/JS workspace (tsc, vitest, an `npx`/`js/`
// invocation) only passes once node_modules is hydrated — so every such
// gate MUST be preceded, IN THE SAME COMMAND, by a `pnpm install`. Without
// it the gate reds on a virgin tree with ~100 phantom cannot-find-module
// errors: a FALSE red that has nothing to do with the change under test.
//
// This walks the live corpus asserts in source order and reds if any
// JS-touching ASSERT CMD is reached before a `pnpm install`. Order is
// load-bearing: a presence-only check (does the command mention pnpm
// install anywhere?) false-greens a REORDERED command where the install
// sits after the gate it is meant to prime. The mutation subtests pin
// exactly that — a reordered synthetic still reds.
//
// The two `node --test cloud/priv/static/__app.test.mjs` console gates run
// the Node test runner against committed .mjs with zero workspace deps, so
// they need no bootstrap. They self-exempt BY TEXT: `node` is deliberately
// NOT a JS token, so no allowlist is required.

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// jsAssertTokens mark an ASSERT CMD as JS-touching — it needs a hydrated
// pnpm workspace to pass. A bare `node` is deliberately excluded (see the
// file header): the console `node --test` gates carry no workspace deps.
var jsAssertTokens = []string{"js/", "pnpm", "npx", "vitest", "tsc"}

func isJSTouching(text string) bool {
	for _, tok := range jsAssertTokens {
		if strings.Contains(text, tok) {
			return true
		}
	}
	return false
}

// scanJSAssertOrder walks cmd's asserts in source order (by Pos.Line) and
// returns the JS-touching AssertCmds reached before any same-command
// `pnpm install` — the false-red order defect — plus the JS-touching and
// self-priming tallies for the census. seenInstall latches BEFORE the flag
// check, so an assert carrying its own `pnpm install` primes itself and is
// never flagged.
func scanJSAssertOrder(cmd *Command) (violations []*Assert, jsTouching, selfPriming int) {
	asserts := append([]*Assert(nil), cmd.Asserts...)
	sort.SliceStable(asserts, func(i, j int) bool { return asserts[i].Pos.Line < asserts[j].Pos.Line })
	seenInstall := false
	for _, a := range asserts {
		if a.Kind != AssertCmd {
			continue
		}
		if strings.Contains(a.Text, "pnpm install") {
			seenInstall = true
		}
		if isJSTouching(a.Text) {
			jsTouching++
			if strings.Contains(a.Text, "pnpm install") {
				selfPriming++
			}
			if !seenInstall {
				violations = append(violations, a)
			}
		}
	}
	return violations, jsTouching, selfPriming
}

// TestCorpusJSAssertClassification walks the live corpus and reds if any
// JS-touching ASSERT CMD lacks a preceding same-command `pnpm install`.
// The census is logged and pinned so a parser regression that drops
// asserts cannot vacuously green this test.
func TestCorpusJSAssertClassification(t *testing.T) {
	totalJS, totalSelfPriming, totalExempt := 0, 0, 0
	var problems []string
	for _, path := range corpusFiles(t) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		cmd, findings := Parse(filepath.Base(path), src)
		if cmd == nil {
			t.Fatalf("%s: Parse returned nil command; findings: %v", filepath.Base(path), findings)
		}
		violations, js, sp := scanJSAssertOrder(cmd)
		totalJS += js
		totalSelfPriming += sp
		// Exempt: an ASSERT CMD that runs `node` but touches no pnpm
		// workspace token — the console `node --test` gates.
		for _, a := range cmd.Asserts {
			if a.Kind == AssertCmd && !isJSTouching(a.Text) && strings.Contains(a.Text, "node") {
				totalExempt++
			}
		}
		for _, v := range violations {
			problems = append(problems, fmt.Sprintf(
				"%s:%d: JS-touching ASSERT CMD reached before a same-command `pnpm install`: %q",
				filepath.Base(path), v.Pos.Line, v.Text))
		}
	}

	t.Logf("JS-assert census across the %d-file corpus: %d JS-touching (%d self-priming, %d order-dependent), %d node --test exempt",
		corpusFileCount, totalJS, totalSelfPriming, totalJS-totalSelfPriming, totalExempt)

	if len(problems) != 0 {
		t.Errorf("%d JS-touching ASSERT CMD(s) lack a preceding `pnpm install` — false red on a fresh worktree:", len(problems))
		for _, p := range problems {
			t.Errorf("  %s", p)
		}
	}

	// Census pin (distrust vacuous green): today's corpus carries exactly
	// 8 JS-touching asserts (2 self-priming `pnpm install`, 6 order-
	// dependent) and 2 node --test exempt. A corpus edit that adds or
	// removes a JS-touching gate updates these on purpose.
	if totalJS != 8 || totalSelfPriming != 2 || totalExempt != 2 {
		t.Errorf("JS-assert census drift: got %d JS-touching / %d self-priming / %d exempt, want 8 / 2 / 2",
			totalJS, totalSelfPriming, totalExempt)
	}
}

// synthJSAssert wraps ASSERT CMD lines in the minimal valid grammar so
// Parse yields a command whose Asserts the guard can walk. No testdata
// file — testdata/red|green is frozen lint-catalog vocabulary (D28).
func synthJSAssert(assertLines string) string {
	return `COMMAND "syn"
DESCRIPTION "synthetic JS-assert fixture."
LAST_UPDATED "16-07-2026-10-00-00"
DOMAIN "barkpark"
TAGS "scaffy, synthetic"
CONCEPT "syn"
VARIANT "default"
DIRECTION "add"

CREATE FILE IF ABSENT "internal/syn/x.go"
::: syn module :::
package syn
::: syn module :::

` + assertLines + "\n"
}

// TestJSAssertOrderMutations proves the guard on synthetic commands: a
// well-formed one is clean, and BOTH failure shapes red — a missing
// precondition and a REORDERED install (order-awareness is load-bearing).
func TestJSAssertOrderMutations(t *testing.T) {
	cases := []struct {
		name      string
		asserts   string
		wantFlags int
	}{
		{
			name: "well-formed: install precedes the JS gate",
			asserts: `ASSERT CMD "cd js && pnpm install && pnpm --filter @barkpark/core build"
ASSERT CMD "cd js/packages/core && npx vitest run"`,
			wantFlags: 0,
		},
		{
			name:      "precondition removed: JS gate with no install",
			asserts:   `ASSERT CMD "cd js/packages/core && npx vitest run"`,
			wantFlags: 1,
		},
		{
			name: "reordered: JS gate before the install line",
			asserts: `ASSERT CMD "cd js/packages/core && npx tsc --noEmit"
ASSERT CMD "cd js && pnpm install && pnpm --filter @barkpark/core build"`,
			wantFlags: 1,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cmd, findings := Parse("synthetic.scaffy", []byte(synthJSAssert(tc.asserts)))
			if cmd == nil {
				t.Fatalf("Parse returned nil command; findings: %v", findings)
			}
			violations, _, _ := scanJSAssertOrder(cmd)
			if len(violations) != tc.wantFlags {
				t.Errorf("got %d flagged, want %d; violations: %v", len(violations), tc.wantFlags, violations)
			}
		})
	}
}
