package cli

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// THE SHARED CORPUS BOTH STRIP IMPLEMENTATIONS ARE MEASURED AGAINST.
//
// testdata/brief_strip_corpus.json is the durable artifact of this finding. It
// exists because the previous shape of this guard was two hand-maintained
// expectation tables — one in Go, one implied by a comment in
// api/lib/barkpark/tasks/brief_mirror.ex — and two hand-maintained copies of a
// rule is exactly how this pair drifted in the first place. One file, read by
// both suites, cannot drift from itself.
//
// WHAT IS IN IT, and why it is not a hand-picked list. 1,313 inputs, generated
// mechanically rather than chosen:
//
//   - combinatorial (1,134): every tuple of length 1..4 over the alphabet
//     {"*", "**", "_", "__", "`", "a"}. Nobody picked these; they are enumerated,
//     so a divergent shape cannot be missed by failing to think of it.
//   - embedded (84): the short tuples wrapped in prose, separating a divergence
//     that only shows at a string boundary from one that shows mid-string.
//   - unterminated (27), runs (16), escaped (15), nested (8), unicode (8),
//     crlf (6), code-span (6), link (4): the edge families a markdown strip is
//     most likely to get wrong — markers with no partner, long marker runs,
//     backslash-escaped markers, interleaved emphasis, multi-byte and fullwidth
//     characters adjacent to markers, CR/LF line endings, code spans whose
//     CONTENT is markup, and links whose text or target is markup.
//   - named (5): the shapes the original finding quoted, carried verbatim so a
//     regeneration of the corpus cannot quietly drop them.
//
// Each row carries `one_pass` (the CANONICAL expectation — see below),
// `three_pass` (what the server produces today), and `divergent`.
//
// THE MEASUREMENT, run on BOTH REAL RUNTIMES, 2026-09-16, worker cli-r20-w54.
// Every input was fed to the real composer here and to the real
// Barkpark.Tasks.BriefMirror.maybe_resync_task_brief/2 loaded from the
// checkout. 19 of 1,313 diverge; 1,294 agree, so the probe discriminates
// rather than reporting difference everywhere. The 19 fall in
// combinatorial (12), unicode (2), named (2), crlf (1), code-span (1), link (1)
// — and EVERY ONE of them contains the same substring, `_**_`. Across the
// escaped, unterminated, nested, runs and embedded families the two agree
// exactly. One mechanism, one shape, now measured rather than assumed.
//
// A DIVERGENCE CLASS THE ORIGINAL FINDING DID NOT NAME, and it is the worst
// one, and it accounts for 10 of the 19: where the description consists ONLY
// of the divergent shape — `_**_`,
// "\r\n_**_\r\n", "`_**_`" — the server's rescanning strip reduces it to the
// empty string, falls through to the auto-stub branch, and replaces the
// author's description with "Complete the work described by “…”". The composer
// keeps `__`. So the divergence is not always "different prose"; sometimes it
// is "the prose is GONE, replaced by a placeholder". No live row is in this
// class today (measured below), but the class exists and belongs in the record.
//
// ONE PASS IS THE CANONICAL SIDE. The grounds are argued in full at
// tasks_brief_strip_parity_test.go and not repeated here: the server declares
// this site as its contract and is the side that breaks it; the composer is
// upstream of the mirror; and rescanning destroys literal characters that only
// became adjacent when a delimiter was removed.
//
// THE REMEDY IS SERVER-SIDE AND ROUTED, not applied here: api/ is another
// lane's fence. task-b641646addba4bdf carries it. Its one line —
// :binary.replace(text, @stripped, "", [:global]) — was run against this whole
// corpus on the real Elixir runtime (against a scratch COPY of the module;
// api/ was not edited) and takes the divergence count from 19 to ZERO on all
// 1,313 inputs. That is the acceptance this fixture exists to give it.
//
// WHAT THE API LANE OWES THIS FILE. A cross-language arm is not complete until
// the Elixir suite reads THIS SAME FILE — a Go re-creation of the Elixir
// behaviour (multiPassStrip, in the sibling file) pins the canonical side but
// cannot red when brief_mirror.ex changes. The Elixir half reads
// ../internal/cli/testdata/brief_strip_corpus.json from api/test and asserts
// its composed purpose-copy equals `one_pass` for every row.
//
// REACHABILITY, RE-MEASURED HERE rather than inherited. 9,786 task documents
// were exported from production on 2026-09-16 (763 drafts; 9,769 carry a string
// `description`, 17 carry no description key at all — note that the 17 are
// MISSING the key, not empty strings, of which there are zero). Running the
// divergence predicate over those 9,769: ONE row diverges, and it is
// task-8ba550b59141bccb — the row that reported the finding, whose description
// quotes the divergent shapes. It is named here because a reader grepping the
// tree for it previously found nothing. Controls printed on the same run so the
// 1 cannot be read as a predicate that never fired: 1,177 descriptions contain
// `**`, 884 contain `__`, 3,948 contain a backtick, and the one-pass strip
// MODIFIED 4,582 of them. So the rule is live everywhere and the DIVERGENCE is
// latent in exactly one place.
//
// A NUMBER NOT TO INHERIT: PR #18522's body quoted "9,356 live task
// descriptions". That figure is verbatim the 2026-09-10 count from
// tooling/grip/ledger/pds-tagregistry-twin-capture-2026-09-10.md and was not
// produced by that run. The denominator is 9,769 as of 2026-09-16.

type briefStripCase struct {
	Input     string `json:"input"`
	OnePass   string `json:"one_pass"`
	ThreePass string `json:"three_pass"`
	Family    string `json:"family"`
	Divergent bool   `json:"divergent"`
}

const briefStripCorpusPath = "testdata/brief_strip_corpus.json"

func loadBriefStripCorpus(t *testing.T) []briefStripCase {
	t.Helper()
	raw, err := os.ReadFile(briefStripCorpusPath)
	if err != nil {
		t.Fatalf("the shared strip corpus is the artifact both implementations are measured against; without it this test asserts nothing: %v", err)
	}
	var cases []briefStripCase
	if err := json.Unmarshal(raw, &cases); err != nil {
		t.Fatalf("%s is unreadable: %v", briefStripCorpusPath, err)
	}
	if len(cases) == 0 {
		t.Fatalf("%s is empty — an empty corpus passes every assertion below while measuring nothing", briefStripCorpusPath)
	}
	return cases
}

// referenceOnePass is an INDEPENDENT left-to-right non-overlapping scanner,
// written deliberately NOT as strings.NewReplacer. The corpus's `one_pass`
// column is checked against it below, so the fixture's expectation is not a
// transcript of the implementation it guards — a guard whose expected value is
// read from the guarded thing is inert.
func referenceOnePass(s string) string {
	patterns := []string{"**", "__", "`"}
	var b strings.Builder
	for i := 0; i < len(s); {
		matched := false
		for _, p := range patterns {
			if strings.HasPrefix(s[i:], p) {
				i += len(p)
				matched = true
				break
			}
		}
		if matched {
			continue
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

// referenceThreePass is the server's current rescanning shape, reproduced only
// so the corpus's `divergent` column can be checked. It is never an expectation.
func referenceThreePass(s string) string {
	for _, p := range []string{"**", "__", "`"} {
		s = strings.ReplaceAll(s, p, "")
	}
	return s
}

// TestBriefStripCorpusColumnsAreDerivable proves the fixture is a statement
// ABOUT the rule rather than a recording of one implementation's output. Every
// column is re-derived here from an independent scanner; a corpus edited to
// match a drifted implementation reds here before it can bless the drift.
func TestBriefStripCorpusColumnsAreDerivable(t *testing.T) {
	for _, tc := range loadBriefStripCorpus(t) {
		if got := referenceOnePass(tc.Input); got != tc.OnePass {
			t.Errorf("corpus row %q: one_pass is %q but the independent scanner gives %q — the fixture no longer states the one-pass rule", tc.Input, tc.OnePass, got)
		}
		if got := referenceThreePass(tc.Input); got != tc.ThreePass {
			t.Errorf("corpus row %q: three_pass is %q but reducing over the patterns gives %q", tc.Input, tc.ThreePass, got)
		}
		if want := tc.OnePass != tc.ThreePass; tc.Divergent != want {
			t.Errorf("corpus row %q: divergent=%v but one_pass %q vs three_pass %q says %v", tc.Input, tc.Divergent, tc.OnePass, tc.ThreePass, want)
		}
	}
}

// TestComposerMatchesSharedStripCorpus is the Go half of the cross-language
// arm: the REAL composer, over the SAME file the Elixir suite is to read.
func TestComposerMatchesSharedStripCorpus(t *testing.T) {
	const stub = "Complete the work described by “strip parity” and record verifiable evidence."

	cases := loadBriefStripCorpus(t)
	divergent, agreeing, stubbing := 0, 0, 0

	for _, tc := range cases {
		want := strings.TrimSpace(tc.OnePass)
		if want == "" {
			want = stub // the composer's empty-description branch
		}
		// THE AUTO-STUB ESCALATION CLASS, counted where it actually lives: the
		// composer keeps prose (one_pass is non-empty) while the server's extra
		// pass reduces the SAME input to nothing and therefore falls through to
		// the placeholder. This is the divergence at its worst — not different
		// prose, but the author's description replaced by boilerplate.
		if strings.TrimSpace(tc.OnePass) != "" && strings.TrimSpace(tc.ThreePass) == "" {
			stubbing++
		}
		body := map[string]any{"title": "strip parity", "description": tc.Input}
		ensureTaskPortableBrief(body)
		if got := purposeCopyText(t, body); got != want {
			t.Errorf("[%s] composer stripped %q to %q, want %q — the composer's strip must stay ONE non-overlapping pass", tc.Family, tc.Input, got, want)
		}
		if tc.Divergent {
			divergent++
		} else {
			agreeing++
		}
	}

	// NON-VACUITY. A corpus that lost its divergent rows, or its agreeing ones,
	// still passes every assertion above while measuring nothing.
	if divergent == 0 {
		t.Fatalf("the corpus carries no divergent row — `_**_` and `foo_**_bar` are the shapes this fixture exists for")
	}
	if agreeing == 0 {
		t.Fatalf("the corpus carries no agreeing row, so it cannot show the probe discriminates rather than reporting difference everywhere")
	}
	if divergent >= agreeing {
		t.Fatalf("%d of %d rows diverge: a corpus that disagrees more often than it agrees is describing a different rule, not this one", divergent, len(cases))
	}
	if stubbing == 0 {
		t.Fatalf("the corpus lost the AUTO-STUB escalation class (a description that is ONLY the divergent shape, which the server erases into the placeholder) — it is the worst consequence of the divergence and must stay represented")
	}

	// The shapes the finding named must be present BY INPUT, not merely by count.
	byInput := make(map[string]briefStripCase, len(cases))
	for _, tc := range cases {
		byInput[tc.Input] = tc
	}
	for _, named := range []string{"_**_", "foo_**_bar", "a_**_b_**_c"} {
		tc, ok := byInput[named]
		if !ok {
			t.Fatalf("the corpus no longer carries %q, the shape the finding was reported on", named)
		}
		if !tc.Divergent {
			t.Fatalf("%q is recorded as agreeing; it is the canonical divergent shape and a corpus that calls it agreeing has been edited to match the drift", named)
		}
	}
	// And a shape that must NOT diverge — the mirror image. Its agreement is
	// what identifies the mechanism as pass ORDER plus rescanning rather than
	// the patterns, so losing it would leave the diagnosis unsupported.
	if tc, ok := byInput["*__*"]; !ok || tc.Divergent {
		t.Fatalf("the corpus must carry `*__*` as an AGREEING shape: the asymmetry between it and `_**_` is what names the mechanism")
	}
}
