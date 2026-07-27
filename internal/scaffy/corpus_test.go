package scaffy

// The corpus conformance harness (charter D30). It freezes the live
// command corpus — scaffy/commands/*.scaffy — as executable law against
// this exact validator + formatter. It is the tripwire that keeps the
// corpus and the package in lockstep forever: any drift in the grammar,
// the lint catalog, the formatter, or the corpus itself turns one of
// these tests red with a diff-style message.
//
// The corpus is read IN PLACE via a relative path (D30: NO go:embed —
// embed cannot reach outside the package directory, and the corpus lives
// at repo-root scaffy/commands, two levels up). `go test` runs with cwd
// set to the package directory, so ../../scaffy/commands resolves.

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// corpusDir is the live command corpus, relative to this package dir
// (go test cwd). NOT copied, NOT embedded — read where it lives (D30).
const corpusDir = "../../scaffy/commands"

// corpusFileCount is the frozen size of the corpus. Asserted first so an
// empty or half-globbed directory can never vacuously pass the per-file
// loops below (distrust vacuous green).
const corpusFileCount = 22

// corpusFiles globs the corpus and fails loudly if the count drifts from
// the frozen size. Every corpus test funnels through here, so a missing
// or added file trips before any per-file assertion runs.
func corpusFiles(t *testing.T) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(corpusDir, "*.scaffy"))
	if err != nil {
		t.Fatalf("glob %s: %v", corpusDir, err)
	}
	sort.Strings(paths)
	if len(paths) != corpusFileCount {
		t.Fatalf("corpus file count drift: found %d .scaffy files in %s, want %d\nfiles: %v",
			len(paths), corpusDir, corpusFileCount, paths)
	}
	return paths
}

// TestCorpusFileCount: exactly corpusFileCount .scaffy files, asserted before anything
// else touches their bytes.
func TestCorpusFileCount(t *testing.T) {
	corpusFiles(t)
}

// TestCorpusParsesZeroFindings: every committed corpus file validates
// clean (no parse error, no lint error, no warn). A red here is a REAL
// spec/corpus divergence — the finding is printed verbatim; never weaken
// this test to make it pass, fix the corpus or raise the spec drift.
func TestCorpusParsesZeroFindings(t *testing.T) {
	for _, path := range corpusFiles(t) {
		t.Run(filepath.Base(path), func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			findings := ValidateFile(filepath.Base(path), src)
			if len(findings) != 0 {
				t.Errorf("%s: expected ZERO findings, got %d:", filepath.Base(path), len(findings))
				for _, f := range findings {
					t.Errorf("  %s", f.String())
					if f.Hint != "" {
						t.Errorf("    hint: %s", f.Hint)
					}
				}
			}
		})
	}
}

// census is the operation tally across the whole corpus, derived from
// the parsed AST (never from regex over the source text).
type census struct {
	create            int // CREATE FILE IF ABSENT
	insertAfterFirst  int // INSERT AFTER FIRST
	insertAfterLast   int // INSERT AFTER LAST
	insertBeforeFirst int // INSERT BEFORE FIRST
	insertBeforeLast  int // INSERT BEFORE LAST
	replace           int // REPLACE
	remove            int // REMOVE
	deleteFile        int // DELETE FILE IF PRESENT
	mark              int // ops carrying a MARK
	markVirtual       int //   of which MARK VIRTUAL
	assertFile        int // ASSERT FILE CONTAINS/DONT CONTAIN/EXISTS/ABSENT
	assertCmd         int // ASSERT CMD
	assertCmdTierCI   int //   of which TIER ci
}

// countCorpus parses each corpus file and folds its AST into the tally.
// It also fails on any parse finding — an unparseable corpus cannot be
// censused, and TestCorpusParsesZeroFindings owns that failure mode too.
func countCorpus(t *testing.T) census {
	t.Helper()
	var c census
	for _, path := range corpusFiles(t) {
		src, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		cmd, findings := Parse(filepath.Base(path), src)
		if cmd == nil {
			t.Fatalf("%s: Parse returned nil command; findings: %v", filepath.Base(path), findings)
		}
		for _, op := range cmd.Ops {
			switch o := op.(type) {
			case *CreateFile:
				c.create++
			case *DeleteFile:
				c.deleteFile++
			case *InOp:
				switch o.Verb {
				case InsertAfterFirst:
					c.insertAfterFirst++
				case InsertAfterLast:
					c.insertAfterLast++
				case InsertBeforeFirst:
					c.insertBeforeFirst++
				case InsertBeforeLast:
					c.insertBeforeLast++
				case Replace:
					c.replace++
				case RemoveVerb:
					c.remove++
				}
				if o.Mark != nil {
					c.mark++
					if o.Mark.Virtual {
						c.markVirtual++
					}
				}
			}
		}
		for _, a := range cmd.Asserts {
			if a.Kind == AssertCmd {
				c.assertCmd++
				if a.Tier == "ci" {
					c.assertCmdTierCI++
				}
			} else {
				c.assertFile++
			}
		}
	}
	return c
}

// TestCorpusCensus: the frozen operation census (charter D30). Derived
// from the parsed AST across all 14 files and matched EXACTLY. Any drift
// — a corpus edit that adds/removes an op, or a parser change that
// classifies one differently — fails here with a field-by-field diff.
func TestCorpusCensus(t *testing.T) {
	want := census{
		create:            30, // +13 2026-07-18 add-site-template: the full Astro starter tree (manifest, schema, seed, app skeleton)
		insertAfterFirst:  46, // +3 2026-07-27 add-block-type Surface 6 (apps/mobile): RN renderer + coreProseRenderers map entry + authored case; +2 2026-07-17: ensure-root-layout-zones' two zone plants; +3: ensure-router-zones' three; +2: add-plugin-bucket's pipeline + wrapper; +1: add-plugin-route's head tuple; +1: ensure-console-hook-zones' tests-zone plant; +3: add-console-helper's skeleton + hook entry + test group; +1: classify-block-type v3's entry plant (was the self-consuming REPLACE — the tiers.ex append-friendly restructure); +9 add-site-template: 2 allowlists + display catalog + 2 lock literals + provisioner row + runtime override + Go want + MANIFEST.md; +2 2026-07-18 composition-seams: add-cli-verb + add-schema-type's wrap retargeted from REPLACE to head-INSERT on add-plugin's opened seams; +1 2026-07-18 add-block-type-syncsites: TEXTLESS_SKIP allow-list entry (site 6)
		insertAfterLast:   1,
		insertBeforeFirst: 4,  // 2026-07-17 INSERT BEFORE ratified: add-canonical-marker's marker plant (was the self-consuming REPLACE); +2: ensure-console-hook-zones' two app.js plants (above the escape hatch; above the IIFE tail); +1 add-site-template: the DeployRequest clause before the catch-all
		insertBeforeLast:  0,  // grammar-legal, zero corpus instances (like SNIPPET/USE — exercised by synthetic fixtures)
		replace:           15, // -1: add-canonical-marker's self-consuming REPLACE became INSERT BEFORE FIRST; -1: classify-block-type v3's became INSERT AFTER FIRST (same-tier refusal killed, 2026-07-17); +3 add-site-template: the three string-literal enumerations (DeployRequest message, sites_deploy_test pin, CLI usage); -2 2026-07-18 composition-seams: add-cli-verb's tail-map REPLACE + add-schema-type's wrap-tail REPLACE both became head-INSERTs on add-plugin's opened seams; +5 2026-07-18 add-block-type-syncsites: 3 showcase census pins (site 4) + 2 toPlainText partition pins (site 6)
		remove:            1,
		deleteFile:        1,
		mark:              67,  // +3 2026-07-27 add-block-type Surface 6: the three RN marks; +2: zone-script-assets + zone-live-hooks; +3: the three router zones; +2: add-plugin-bucket's pipeline + scope marks; +1: add-plugin-route; +3: the three console zones; +3: add-console-helper's trio; +13 add-site-template: 10 planted + 3 virtual; +6 2026-07-18 add-block-type-syncsites: 5 Surface-5 pin bumps + 1 TEXTLESS_SKIP entry
		markVirtual:       5,   // +3 add-site-template: string-literal REPLACEs (no comment survives in a string)
		assertFile:        119, // +3 2026-07-27 add-block-type Surface 6: the three RN mark postconditions; +1 2026-07-23 add-oban-worker: loud-fail cron-guard-gap postcondition (ASSERT FILE config.exs CONTAINS the requested tuple, D90); +2: the two zone-declaration postconditions; +3: the router trio; +3: add-plugin-bucket's two marks + collector line; +2: add-plugin-route's mark + tuple tail; +3: the console-zone trio; +3: add-console-helper's trio; -1: classify v3 dropped its MARK assert (D57 postcondition shape — the entry assert alone holds on the hand-edit path); +27 add-site-template: per-family-member postconditions; +4 2026-07-18 composition-seams: add-plugin's four seam postconditions (register_routes + cli_commands openers, both register-schemas zone marks); +4 2026-07-18 add-block-type-syncsites: Surface-5 postconditions (showcase pin mark, 2 toPlainText pins, plaintext-skip mark)
		assertCmd:         49,  // +3 2026-07-27 add-block-type Surface 6: root pnpm install+build, mobile typecheck, mobile jest (all LOCAL — the root workspace is a DIFFERENT one from js/, so this leg is self-priming); +2: the two `cd api && mix compile` (TIER ci) HEEx/router proofs; +1: add-plugin-bucket's; +1: add-plugin-route's; +2: the console pair's LOCAL `node --test` gates; +5 add-site-template: sync + Go lock + vet LOCAL, two Elixir gates ci; +4 2026-07-18 add-block-type-syncsites: showcase gen + test + cloud sync LOCAL, drift test ci (react vitest relocated, not added)
		assertCmdTierCI:   17,  // +2: same — the corpus's HEEx + router compile proofs; +1: add-plugin-bucket's; +1: add-plugin-route's (the console pair's node gates are LOCAL, not ci); +2 add-site-template: the cloud + api mix gates; +1 2026-07-18 add-block-type-syncsites: the cloud drift test
	}
	got := countCorpus(t)
	if got != want {
		t.Errorf("corpus census drift:\n%s", censusDiff(want, got))
	}
}

// censusDiff renders a field-by-field want/got table, marking the rows
// that differ so a red test names exactly what moved.
func censusDiff(want, got census) string {
	rows := []struct {
		name      string
		want, got int
	}{
		{"CREATE", want.create, got.create},
		{"INSERT AFTER FIRST", want.insertAfterFirst, got.insertAfterFirst},
		{"INSERT AFTER LAST", want.insertAfterLast, got.insertAfterLast},
		{"INSERT BEFORE FIRST", want.insertBeforeFirst, got.insertBeforeFirst},
		{"INSERT BEFORE LAST", want.insertBeforeLast, got.insertBeforeLast},
		{"REPLACE", want.replace, got.replace},
		{"REMOVE", want.remove, got.remove},
		{"DELETE", want.deleteFile, got.deleteFile},
		{"MARK", want.mark, got.mark},
		{"MARK VIRTUAL", want.markVirtual, got.markVirtual},
		{"ASSERT FILE", want.assertFile, got.assertFile},
		{"ASSERT CMD", want.assertCmd, got.assertCmd},
		{"ASSERT CMD TIER ci", want.assertCmdTierCI, got.assertCmdTierCI},
	}
	var b bytes.Buffer
	b.WriteString("  op                    want   got\n")
	for _, r := range rows {
		mark := "   "
		if r.want != r.got {
			mark = " <-"
		}
		b.WriteString(padRight("  "+r.name, 24))
		b.WriteString(padLeft(itoa(r.want), 4))
		b.WriteString(padLeft(itoa(r.got), 6))
		b.WriteString(mark + "\n")
	}
	return b.String()
}

func padRight(s string, n int) string {
	for len(s) < n {
		s += " "
	}
	return s
}

func padLeft(s string, n int) string {
	for len(s) < n {
		s = " " + s
	}
	return s
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// TestCorpusFmtFixpoint: every corpus file is already in canonical form
// — Format(src) == src byte-for-byte — and Format is idempotent on it.
// The corpus IS the fmt golden. A red here means either a corpus file
// drifted from canonical spelling or the formatter changed under it;
// the diff shows the first offending byte region.
func TestCorpusFmtFixpoint(t *testing.T) {
	for _, path := range corpusFiles(t) {
		t.Run(filepath.Base(path), func(t *testing.T) {
			src, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", path, err)
			}
			once, err := Format(src)
			if err != nil {
				t.Fatalf("%s: Format errored on a corpus file: %v", filepath.Base(path), err)
			}
			if !bytes.Equal(once, src) {
				t.Errorf("%s: not canonical — Format(src) != src\n%s", filepath.Base(path), firstDiff(src, once))
			}
			twice, err := Format(once)
			if err != nil {
				t.Fatalf("%s: Format(Format(src)) errored: %v", filepath.Base(path), err)
			}
			if !bytes.Equal(twice, once) {
				t.Errorf("%s: Format is not idempotent\n%s", filepath.Base(path), firstDiff(once, twice))
			}
		})
	}
}

// firstDiff reports the first byte offset and line where want and got
// diverge, with a short window of context each side — a diff-style hint
// rather than dumping two whole files.
func firstDiff(want, got []byte) string {
	n := len(want)
	if len(got) < n {
		n = len(got)
	}
	i := 0
	for i < n && want[i] == got[i] {
		i++
	}
	line := 1
	for j := 0; j < i && j < len(want); j++ {
		if want[j] == '\n' {
			line++
		}
	}
	lo := i - 40
	if lo < 0 {
		lo = 0
	}
	whi := i + 40
	if whi > len(want) {
		whi = len(want)
	}
	ghi := i + 40
	if ghi > len(got) {
		ghi = len(got)
	}
	var b bytes.Buffer
	b.WriteString("  first diff at byte " + itoa(i) + " (line " + itoa(line) + "):\n")
	b.WriteString("  --- src  ---\n  " + string(want[lo:whi]) + "\n")
	b.WriteString("  --- fmt  ---\n  " + string(got[lo:ghi]) + "\n")
	return b.String()
}
