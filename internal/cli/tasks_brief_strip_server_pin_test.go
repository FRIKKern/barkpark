package cli

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// tasks_brief_strip_server_pin_test.go — THE TWO ARMS task-8ba550b59141bccb's
// criterion 1 said were missing on this side, built inside the CLI fence.
//
// THE STATE THIS FILE FOUND. The purpose-copy strip exists in THREE Go places
// and one Elixir place, and until now only two of the four were tied to the
// shared corpus:
//
//   1. briefPurposeStripOnePass (tasks_brief_mirror_warn.go) — the canonical
//      rule the composer writes with. PINNED to all 1,313 corpus rows by
//      TestComposerMatchesSharedStripCorpus.
//   2. referenceOnePass / referenceThreePass (tasks_brief_strip_corpus_test.go)
//      — independent scanners that keep the FIXTURE honest. Pinned.
//   3. briefPurposeStripLegacyThreePass (tasks_brief_mirror_warn.go) — a Go
//      COPY OF THE SERVER'S RULE, used as the reader-side TOLERANCE. Pinned
//      only by a FIVE-ROW hand-written table
//      (TestBriefMirrorStripRulesDisagreeAsRecorded).
//   4. Barkpark.Tasks.BriefMirror.strip_markdown/1 (api/) — the rule (3) claims
//      to reproduce. Pinned by NOTHING on this side.
//
// (3) AND (4) ARE THE EXACT DRIFT SHAPE THIS ROW IS ABOUT. The row's own
// disposition says the fix for this family was "one corpus instead of two
// hand-maintained copies of the expectations, which is exactly how this pair
// drifted" — and then the tolerance shipped as a third hand-maintained copy,
// measured against five cases out of 1,313.
//
// AND THE TOLERANCE IS NOT COSMETIC. briefMirrorDivergenceOf stays QUIET when a
// brief matches briefPurposeStripLegacyThreePass. So if that copy drifts from
// what the server actually runs, the warning fails in both directions at once:
// it fires on rows the server mirrored faithfully, and it stays silent on rows
// that genuinely diverge. A five-case table cannot see either.
//
// ARM ONE (behaviour) pins the tolerance to the same 1,313 rows the composer is
// pinned to. ARM TWO (cross-fence tripwire) is the one that makes the sentence
// "editing brief_mirror.ex reds nothing" stop being true: it reads the server
// module and fails when the shape (3) imitates is no longer the shape (4) has.
//
// WHAT ARM TWO IS, STATED HONESTLY. It is a SOURCE pin, not a behaviour pin. It
// does not execute Elixir and it is not the cross-language arm criterion 1 asks
// for — that arm needs an ExUnit reader of this same corpus and lives in the
// api lane's fence (task-b641646addba4bdf). What it does do is make a change to
// the server's strip impossible to land SILENTLY as far as this side is
// concerned, which is the specific failure that produced this row: a comment at
// both sites saying the two must match, and nothing that reds when they stop.

// serverBriefMirrorPath is read, never written — api/ is another lane's fence.
const serverBriefMirrorPath = "../../api/lib/barkpark/tasks/brief_mirror.ex"

// ARM ONE. The tolerance is a copy of a foreign implementation; measure it
// against the shared corpus rather than against five remembered cases.
func TestLegacyThreePassToleranceMatchesSharedCorpus(t *testing.T) {
	cases := loadBriefStripCorpus(t)

	divergent, agreeing := 0, 0
	for _, tc := range cases {
		// The corpus columns are UNTRIMMED; both strip helpers trim, because
		// compose_purpose/3 and the composer both trim after stripping.
		want := strings.TrimSpace(tc.ThreePass)
		if got := briefPurposeStripLegacyThreePass(tc.Input); got != want {
			t.Errorf("briefPurposeStripLegacyThreePass(%q) = %q, corpus three_pass says %q — the Go copy of the SERVER's rule has drifted from the shared corpus", tc.Input, got, want)
		}
		if strings.TrimSpace(tc.OnePass) != want {
			divergent++
		} else {
			agreeing++
		}
	}

	// NON-VACUITY, both directions. A corpus of only-agreeing rows would pass
	// every assertion above while proving the tolerance is a second spelling of
	// briefPurposeStripOnePass; a corpus of only-divergent rows would mean the
	// comparison never sees a normal description.
	if divergent == 0 {
		t.Fatalf("no corpus row distinguishes the two rules, so this test cannot tell the tolerance from the canonical rule: %d rows, all agreeing", len(cases))
	}
	if agreeing == 0 {
		t.Fatalf("every corpus row diverges — a uniform verdict is the signature of a broken comparator, not of a finding: %d rows", len(cases))
	}
	t.Logf("tolerance measured against %d corpus rows: %d divergent, %d agreeing", len(cases), divergent, agreeing)
}

// ARM TWO. The cross-fence tripwire. Its job is to red the moment the server's
// strip stops being the shape briefPurposeStripLegacyThreePass reproduces —
// which today means the moment task-b641646addba4bdf lands its remedy.
func TestServerStripShapeIsStillTheThreePassReduce(t *testing.T) {
	raw, err := os.ReadFile(serverBriefMirrorPath)
	// A MISSING FILE IS A FAILURE, NOT A SKIP. An absent read is exactly how a
	// tripwire on a path in another tree goes quietly vacuous: the module gets
	// moved, the test stops finding it, and a green suite reports agreement it
	// never measured.
	if err != nil {
		t.Fatalf("%s is unreadable, so this tripwire measured NOTHING: %v\nIf BriefMirror moved, re-point this constant — do not delete the arm.", serverBriefMirrorPath, err)
	}
	src := string(raw)

	// CONTROL on the read itself: prove we are looking at the right module
	// before drawing any conclusion from what we do or do not find in it. A
	// grep over the wrong file answers "absent" just as confidently.
	for _, anchor := range []string{"defmodule Barkpark.Tasks.BriefMirror", "defp strip_markdown(", "@stripped"} {
		if !strings.Contains(src, anchor) {
			t.Fatalf("%s does not contain %q, so it is not the module this arm pins and every verdict below would be drawn from the wrong file", serverBriefMirrorPath, anchor)
		}
	}

	// The token set. The corpus's three_pass column and the Go tolerance both
	// hard-code these three; a fourth token on the server silently widens what
	// the tolerance forgives.
	stripped := regexp.MustCompile(`@stripped\s+\[([^\]]*)\]`).FindStringSubmatch(src)
	if stripped == nil {
		t.Fatalf("could not find the @stripped list in %s; briefPurposeStripLegacyThreePass claims to reproduce it and can no longer be checked against it", serverBriefMirrorPath)
	}
	if got := strings.Join(strings.Fields(stripped[1]), " "); got != `"**", "__", "`+"`"+`"` {
		t.Fatalf("the server's @stripped is now [%s].\nbriefPurposeStripLegacyThreePass (tasks_brief_mirror_warn.go) and testdata/brief_strip_corpus.json's `three_pass` column both hard-code the three tokens `**`, `__` and a backtick. Re-derive the corpus and update the tolerance before this warning is trusted again.", got)
	}

	// The SHAPE. `Enum.reduce(@stripped, text, &String.replace(...))` is the
	// rescanning, three-pass form. Matched on the normalised source so that
	// reformatting brief_mirror.ex does not red this arm; only the CALL changes.
	flat := strings.Join(strings.Fields(src), " ")
	if !strings.Contains(flat, `defp strip_markdown(text), do: Enum.reduce(@stripped, text, &String.replace(&2, &1, ""))`) {
		t.Fatalf(`the server's strip_markdown/1 is no longer the three-pass Enum.reduce over @stripped.

THIS IS THE EXPECTED FAILURE WHEN task-b641646addba4bdf LANDS, and it is not a defect in this test — it is the tripwire doing its job. The remedy, in order:

  1. Re-measure the server against internal/cli/testdata/brief_strip_corpus.json on a real Elixir runtime. If the new shape is the routed single-pass :binary.replace(text, @stripped, "", [:global]), it agrees with the canonical rule on all 1,313 rows.
  2. Then DELETE briefPurposeStripLegacyThreePass and the "got == briefPurposeStripLegacyThreePass(...)" tolerance in briefMirrorDivergenceOf (tasks_brief_mirror_warn.go). Keeping it would suppress real divergence warnings on behalf of a rule nothing runs any more.
  3. Then delete this arm, and TestLegacyThreePassToleranceMatchesSharedCorpus with it.

Do NOT silence this by relaxing the match. The whole finding behind task-8ba550b59141bccb is that a COMMENT asserting the two sites agree is what let them drift for months.`)
	}
}
