package cli

import (
	"strings"
	"testing"
)

// THE COMPOSER'S MARKDOWN STRIP IS ONE PASS, AND THAT IS THE CANONICAL RULE.
//
// ensureTaskPortableBrief composes `purpose-copy` from `description` through
// strings.NewReplacer("**", "", "__", "", "`", ""): ONE non-overlapping
// left-to-right pass that considers all three patterns at once. The server's
// BriefMirror re-derives the same block on every subsequent write, and
// api/lib/barkpark/tasks/brief_mirror.ex says at its @stripped table that it
// mirrors this site "EXACTLY — a normaliser more aggressive than the Go source
// would rewrite prose the composer would have kept".
//
// It is not exact today. The server reduces over the three patterns, three
// passes each over the previous pass's output, so it RESCANS: removing `**`
// from `foo_**_bar` brings two `_` together and the next pass eats them. The
// one-pass form has already advanced past that position and never looks again.
// Measured on both real runtimes, 2026-09-16:
//
//	input          one pass (this file)   three passes (server)
//	"_**_"         "__"                   ""
//	"foo_**_bar"   "foo__bar"             "foobar"
//	"a_**_b_**_c"  "a__b__c"              "abc"
//	"*__*"         "**"                   "**"          <- agree
//	"x__**__y"     "xy"                   "xy"          <- agree
//	"_**bold**_"   "_bold_"               "_bold_"      <- agree
//
// The asymmetry names the mechanism: `_**_` diverges and its mirror image
// `*__*` does not, because the `**` pattern is reduced FIRST. The divergence
// is in pass ORDER plus rescanning, not in the patterns.
//
// ONE PASS IS THE CORRECT SIDE, on three grounds:
//
//  1. The server states this site as its contract and is the side that breaks
//     it. A mirror that transforms differently from the thing it mirrors is
//     broken whichever output you happen to prefer.
//  2. The composer is upstream. The CLI writes the brief at create; the server
//     RE-DERIVES it. Matching runs composer -> mirror, not the reverse.
//  3. Rescanning destroys literal prose. In `foo_**_bar` the two `_` are
//     separate literal characters the person typed; only the removal of `**`
//     juxtaposes them. One pass removes exactly the byte ranges that were
//     delimiters IN THE INPUT. A purpose-copy mirror whose whole job is not to
//     rewrite prose must be the conservative one.
//
// So the remedy is server-side and belongs to the api lane, not here — a
// single-pass BIF, :binary.replace(text, @stripped, "", [:global]), reproduces
// every row of the table above (verified on the real runtime). This file does
// the half that IS this fence's: it freezes the canonical side so the CLI
// cannot drift onto the aggressive form while that fix is pending, and so the
// server's fix has a written expectation to land against.
//
// REACHABILITY, MEASURED rather than assumed. The divergence predicate —
// one-pass output != three-pass output — was run over the live corpus. ONE row
// diverges, and it is task-8ba550b59141bccb: the row that reported the finding,
// whose description quotes the shapes. Every other live description is
// unaffected, so this is LATENT in the corpus and live in exactly one place.
// The controls below fired on that same run, so the predicate was shown to
// discriminate rather than to answer zero everywhere.
//
// A CORRECTION TO THIS PARAGRAPH'S OWN FIRST DRAFT, kept rather than silently
// overwritten. PR #18522 stated the denominator as "9,356 live task
// descriptions (17 of them empty)". 9,356 is verbatim the 2026-09-10 figure in
// tooling/grip/ledger/pds-tagregistry-twin-capture-2026-09-10.md and was not
// produced by that run. Re-measured on 2026-09-16 (worker cli-r20-w54): 9,786
// task documents exported, 763 of them drafts, 9,769 carrying a string
// `description`; the 17 are rows carrying NO description key, not empty
// strings, of which there are zero. The verdict — one diverging row — survives
// the correction; the denominator does not. Controls printed on that run:
// 1,177 descriptions contain `**`, 884 contain `__`, 3,948 contain a backtick,
// and the one-pass strip modified 4,582 of them.
//
// A BROADER DIFFERENTIAL now supersedes the eight-case table above, and the
// shared fixture it runs on is testdata/brief_strip_corpus.json: 1,313
// mechanically generated inputs, fed to BOTH real runtimes, 19 diverging.
// See tasks_brief_strip_corpus_test.go.

// multiPassStrip is the SERVER's current shape, reproduced here only as a
// control. It is never the expectation: it exists so this test can prove it
// SEES a disagreement it was not written against.
func multiPassStrip(s string) string {
	for _, pattern := range []string{"**", "__", "`"} {
		s = strings.ReplaceAll(s, pattern, "")
	}
	return s
}

func composedPurposeCopy(t *testing.T, description string) string {
	t.Helper()
	body := map[string]any{"title": "strip parity", "description": description}
	ensureTaskPortableBrief(body)
	return purposeCopyText(t, body)
}

func TestComposerStripsMarkdownInOneNonOverlappingPass(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
		// divergent records whether the server's three-pass form disagrees
		// with want. It is asserted in BOTH directions below.
		divergent bool
	}{
		{name: "underscore wrapping bold, nothing between", in: "_**_", want: "__", divergent: true},
		{name: "divergent shape embedded in prose", in: "foo_**_bar", want: "foo__bar", divergent: true},
		{name: "the shape twice", in: "a_**_b_**_c", want: "a__b__c", divergent: true},
		{name: "the mirror image does not diverge", in: "*__*", want: "**"},
		{name: "adjacent patterns collapse the same either way", in: "x__**__y", want: "xy"},
		{name: "bold inside emphasis", in: "_**bold**_", want: "_bold_"},
		{name: "code span", in: "`a`", want: "a"},
		{name: "plain bold", in: "**x**", want: "x"},
		{name: "single markers are not stripped", in: "_*_*_", want: "_*_*_"},
		{name: "prose with no markers", in: "a plain description", want: "a plain description"},
	}

	sawDivergent, sawAgreeing := 0, 0
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := composedPurposeCopy(t, tc.in); got != tc.want {
				t.Fatalf("composer stripped %q to %q, want %q — the composer's strip must stay ONE non-overlapping pass; a rescanning form eats literal characters that only became adjacent when a delimiter was removed", tc.in, got, tc.want)
			}

			// THE POSITIVE CONTROL. For the divergent shapes the server's
			// three-pass form must NOT reach `want`: if it did, this test
			// would be blind to the very drift it exists to catch. For the
			// rest it must agree, which is the quiet arm — a harness that
			// reported a disagreement everywhere would discriminate nothing.
			server := multiPassStrip(tc.in)
			if tc.divergent {
				if server == tc.want {
					t.Fatalf("control failed: the three-pass form now agrees with the composer on %q (both %q). Either the server's shape was mirrored into this control, or this case stopped being a divergent shape; in both cases this test can no longer see the drift it guards", tc.in, server)
				}
				sawDivergent++
				return
			}
			if server != tc.want {
				t.Fatalf("control failed: %q was listed as agreeing, but the three-pass form gives %q against the composer's %q", tc.in, server, tc.want)
			}
			sawAgreeing++
		})
	}

	// A table that lost its divergent shapes, or lost its agreeing ones, still
	// passes every case above while measuring nothing. Both arms must exist.
	if sawDivergent == 0 {
		t.Fatalf("the table carries no divergent shape: `_**_` and `foo_**_bar` are the cases this test exists for")
	}
	if sawAgreeing == 0 {
		t.Fatalf("the table carries no agreeing shape, so it cannot show that the probe discriminates")
	}
}
