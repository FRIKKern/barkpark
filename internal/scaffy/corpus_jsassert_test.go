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
// The two console gates run the Node test runner against committed .mjs
// with zero workspace deps, so they need no bootstrap. They used to
// self-exempt BY TEXT (`node` is deliberately NOT a JS token, so no
// allowlist is required). Since 9e8126153 (#17867, 2026-09-11) they read
// `sh scripts/console-harness.sh` instead, and a shell script is OPAQUE to
// a text-keyed predicate: the assert mentions neither a JS token nor
// `node`, so it fell out of BOTH arms silently. That is the blind spot
// this file now names rather than guesses at — see classifyAssert.

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

// repoRoot is the repository root relative to this package dir (go test
// cwd) — the same anchor corpusDir is written against (D30).
const repoRoot = "../.."

// delegatedScriptRefs returns the repo-relative shell scripts an ASSERT CMD
// hands its work to (`sh scripts/x.sh`, `bash scripts/x.sh`, `./scripts/x.sh`).
//
// WHY THIS EXISTS. A text-keyed classifier cannot see past a script name:
// `sh scripts/console-harness.sh` mentions no JS token and no `node`, so
// before this it was classified as NOTHING — invisible to the order guard
// AND absent from the census, which is exactly how the exempt term fell
// from 2 to 0 on 2026-09-11 with no corpus gate becoming safer.
//
// Reading the script's BYTES and token-scanning them was measured and
// REJECTED on 2026-09-13: of the four scripts the corpus delegates to,
// console-harness.sh carries `js/` inside `installs/nodejs/`,
// docs-anchors-check.sh carries `pnpm` and `npx` inside a CMD_VERBS regex
// alternation, and check-doc-budgets.sh carries `js/CLAUDE.md` as a budget
// path. Three of four would be classified JS-touching on prose and paths
// alone. So delegation is surfaced as its OWN pinned census class and
// adjudicated by a human once per change, instead of being guessed at.
func delegatedScriptRefs(text string) []string {
	var refs []string
	for _, f := range strings.Fields(text) {
		f = strings.Trim(f, "\"'`();|&")
		f = strings.TrimPrefix(f, "./")
		if strings.HasSuffix(f, ".sh") {
			refs = append(refs, f)
		}
	}
	return refs
}

// assertClass is the census class of one ASSERT CMD.
type assertClass int

const (
	classPlain      assertClass = iota // touches neither JS, a script, nor node
	classJSTouching                    // needs a hydrated pnpm workspace
	classDelegated                     // hands off to a repo shell script — OPAQUE
	classNodeExempt                    // runs node directly, no workspace token
)

// classifyAssert is THE code path that decides exemption. Order is
// load-bearing and is the whole adjudication: a JS token in the assert's
// own text wins (it is the dangerous class); a delegation to a repo script
// is next, because the script's name tells us nothing and a guess here is
// how the detector went blind; only a DIRECT `node` with no JS token and no
// delegation is exempt.
func classifyAssert(text string) assertClass {
	if isJSTouching(text) {
		return classJSTouching
	}
	if len(delegatedScriptRefs(text)) > 0 {
		return classDelegated
	}
	if strings.Contains(text, "node") {
		return classNodeExempt
	}
	return classPlain
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
	totalJS, totalSelfPriming, totalExempt, totalDelegated := 0, 0, 0, 0
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
		for _, a := range cmd.Asserts {
			if a.Kind != AssertCmd {
				continue
			}
			switch classifyAssert(a.Text) {
			case classNodeExempt:
				totalExempt++
			case classDelegated:
				totalDelegated++
				// A delegation to a script that is not in the tree is a
				// broken gate, and it is also the shape that would let a
				// delegated assert be "classified" against nothing.
				for _, ref := range delegatedScriptRefs(a.Text) {
					if _, err := os.Stat(filepath.Join(repoRoot, ref)); err != nil {
						problems = append(problems, fmt.Sprintf(
							"%s:%d: ASSERT CMD delegates to %q, which is not in the tree: %v",
							filepath.Base(path), a.Pos.Line, ref, err))
					}
				}
			}
		}
		for _, v := range violations {
			problems = append(problems, fmt.Sprintf(
				"%s:%d: JS-touching ASSERT CMD reached before a same-command `pnpm install`: %q",
				filepath.Base(path), v.Pos.Line, v.Text))
		}
	}

	t.Logf("JS-assert census across the %d-file corpus: %d JS-touching (%d self-priming, %d order-dependent), %d direct node --test exempt, %d delegated to a repo script",
		corpusFileCount, totalJS, totalSelfPriming, totalJS-totalSelfPriming, totalExempt, totalDelegated)

	if len(problems) != 0 {
		t.Errorf("%d JS-touching ASSERT CMD(s) lack a preceding `pnpm install` — false red on a fresh worktree:", len(problems))
		for _, p := range problems {
			t.Errorf("  %s", p)
		}
	}

	// Census pin (distrust vacuous green): today's corpus carries exactly
	// 11 JS-touching asserts (3 self-priming `pnpm install`, 8 order-
	// dependent), 0 asserts that run `node` DIRECTLY, and 7 that delegate
	// to a committed repo script. A corpus edit that adds or removes a
	// JS-touching gate, or introduces a new delegation, updates these on
	// purpose — and a new delegation MUST be adjudicated by hand, because
	// classifyAssert deliberately refuses to guess what a script runs.
	//
	// +3 JS-touching / +1 self-priming on 2026-07-27: add-block-type's
	// Surface 6 (apps/mobile) leg. It carries its OWN `pnpm install`
	// because the repo has TWO independent pnpm workspaces — the root one
	// (web, js/packages/*, apps/mobile) and js/'s own (packages/*, docs) —
	// so the earlier `cd js && pnpm install` hydrates the wrong tree and
	// primes nothing for the mobile gates.
	//
	// exempt 2 -> 0, delegated +2 on 2026-09-13 (the change landed
	// 2026-09-11 in 9e8126153, #17867): add-console-helper.scaffy:155 and
	// ensure-console-hook-zones.scaffy:191 moved from
	// `ASSERT CMD "node --test cloud/priv/static/__app.test.mjs"` to
	// `ASSERT CMD "sh scripts/console-harness.sh"`. THE WORLD DID NOT
	// IMPROVE: scripts/console-harness.sh still ends `exec "$node" --test
	// "$ROOT/$TEST_REL"` and invokes no pnpm/npx/vitest/tsc anywhere, so
	// those two gates still need no workspace bootstrap and still deserve
	// the exemption — it moved BEHIND a script the classifier could not
	// see through. The exempt pin therefore does NOT drop to a bare 0 on
	// its own; it drops to 0 alongside a delegated term that recovers the
	// sight, so the two gates are still counted and a THIRD delegation
	// cannot arrive unnoticed. The other five delegations predate this and
	// were measured on 2026-09-13, per assert, not per script name (a
	// distinct-script count is 4 and is the WRONG number here):
	// add-canonical-marker:104 and add-docs-card:151 and
	// remove-docs-card:101 -> scripts/docs-anchors-check.sh,
	// add-block-type:731 -> scripts/pd-parity-completeness.sh,
	// remove-docs-card:100 -> scripts/check-doc-budgets.sh.
	// exempt 0 -> 1 on 2026-09-17 (task-e4289e4c30bb6eff):
	// ensure-console-hook-zones gained
	// `ASSERT CMD "node scripts/console-tdz-order-check.mjs
	// cloud/priv/static/__app.test.mjs"` — the ZONE ANCHOR ORDER guard that
	// makes OP 3's position prose machine-checked. It runs `node` DIRECTLY on
	// a committed .mjs with zero workspace deps (node:fs only, by that
	// script's own header), names no JS token, and delegates to no shell
	// script, so classifyAssert reads classNodeExempt and the exemption is
	// EARNED, not inherited: no `pnpm install` can prime anything it needs.
	// This term is also the reversion detector for that template edit — drop
	// the assert and this reads 0 against a want of 1.
	if totalJS != 11 || totalSelfPriming != 3 || totalExempt != 1 || totalDelegated != 7 {
		t.Errorf("JS-assert census drift: got %d JS-touching / %d self-priming / %d direct-node exempt / %d delegated, want 11 / 3 / 1 / 7",
			totalJS, totalSelfPriming, totalExempt, totalDelegated)
	}
}

// TestJSAssertClassification pins classifyAssert itself — the code path
// that decides exemption. Without this the census pin is the only thing
// holding the classifier, and a census pin cannot tell a class that moved
// from a class that disappeared. The `sh scripts/console-harness.sh` arm
// is the literal 2026-09-11 regression: before delegation was a class it
// returned classPlain, invisible to every term.
func TestJSAssertClassification(t *testing.T) {
	cases := []struct {
		text string
		want assertClass
	}{
		{"node --test cloud/priv/static/__app.test.mjs", classNodeExempt},
		{"sh scripts/console-harness.sh", classDelegated},
		{"bash scripts/docs-anchors-check.sh", classDelegated},
		{"./scripts/console-harness.sh", classDelegated},
		{"cd js/packages/core && npx vitest run", classJSTouching},
		{"cd js && pnpm install && pnpm --filter @barkpark/core build", classJSTouching},
		{"cd api && mix compile", classPlain},
		// A delegation that ALSO names a JS token in its own text stays in
		// the dangerous class — the order guard must keep flagging it.
		{"cd js/packages/core && sh scripts/console-harness.sh", classJSTouching},
	}
	for _, tc := range cases {
		if got := classifyAssert(tc.text); got != tc.want {
			t.Errorf("classifyAssert(%q) = %v, want %v", tc.text, got, tc.want)
		}
	}
}

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
