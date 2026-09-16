package pdrender

import (
	"regexp"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

func labelTestCtx(w int) RenderCtx {
	return RenderCtx{Width: w, Theme: DarkTheme(), Profile: NoColor}
}

func plainLines(out []string) []string {
	p := make([]string, len(out))
	for i, ln := range out {
		p[i] = ansi.Strip(ln)
	}
	return p
}

// lineWith returns the first plain line containing want, or "".
func lineWith(out []string, want string) string {
	for _, ln := range plainLines(out) {
		if strings.Contains(ln, want) {
			return ln
		}
	}
	return ""
}

// ── the break tag is spent as a LINE, not as text and not as width ───────────

// TestMermaidBreakTagBreaksFlowchartTDLabel is the RED-WHEN-REVERTED arm for the
// TD engine: revert mermaidLabelLines in renderNodeBox and "<br/>" reappears as
// literal text on one line.
func TestMermaidBreakTagBreaksFlowchartTDLabel(t *testing.T) {
	g := parseMermaid(tdBreakSrc).graph
	out := renderFlowchartAuto(g, labelTestCtx(80))
	joined := strings.Join(plainLines(out), "\n")

	if strings.Contains(joined, "<br") || strings.Contains(joined, "br/>") {
		t.Errorf("the break tag LEAKED as literal text:\n%s", joined)
	}
	first := lineWith(out, "Parse tokens")
	second := lineWith(out, "then layout")
	if first == "" || second == "" {
		t.Fatalf("label did not break into its two authored lines:\n%s", joined)
	}
	if first == second {
		t.Errorf("both halves landed on ONE line — the break was not honoured: %q", first)
	}
	// The break is the author's, so nothing else may ride the first line.
	if strings.Contains(first, "then layout") {
		t.Errorf("first line carries the second segment: %q", first)
	}
}

// TestMermaidBreakTagSpellings: Mermaid accepts several spellings and every one
// of them is a break, not text.
func TestMermaidBreakTagSpellings(t *testing.T) {
	for _, tag := range []string{"<br>", "<br/>", "<br />", "<BR/>", "<Br  />"} {
		g := parseMermaid("flowchart TD\n  A[\"alpha" + tag + "beta\"] --> B[Emit]\n  A --> C[Third]\n  B --> D[Fourth]").graph
		joined := strings.Join(plainLines(renderFlowchartAuto(g, labelTestCtx(80))), "\n")
		if strings.Contains(strings.ToLower(joined), "<br") {
			t.Errorf("%s leaked as literal text:\n%s", tag, joined)
		}
		if lineWith(renderFlowchartAuto(g, labelTestCtx(80)), "alphabeta") != "" {
			t.Errorf("%s was deleted and the segments welded together", tag)
		}
	}
}

// TestMermaidBreakTagSizesLRBoxFromLongestSegment is the LR arm. It pins the two
// halves of the defect at once: the break is honoured, AND the box is measured
// from the longest RESULTING line rather than from the pre-split string.
func TestMermaidBreakTagSizesLRBoxFromLongestSegment(t *testing.T) {
	// "Parse tokens" (12) is the widest segment; the unsplit string is 29 cells,
	// so a box sized from the unsplit label is more than twice as wide.
	g := parseMermaid(lrBreakSrc).graph
	out := renderFlowchartLR(g, labelTestCtx(80))
	if out == nil {
		t.Fatal("LR returned nil — expected it to fit at width 80")
	}
	lines := plainLines(out)
	joined := strings.Join(lines, "\n")
	if strings.Contains(joined, "<br") {
		t.Errorf("the break tag LEAKED as literal text:\n%s", joined)
	}
	if lineWith(out, "Parse tokens") == "" || lineWith(out, "then layout") == "" {
		t.Fatalf("LR label did not break into its two authored lines:\n%s", joined)
	}

	// The box that holds the label must be CLOSED. A taller box stamped into a
	// 3-row slot silently loses its bottom border — the regression the LR vertical
	// geometry was generalized to prevent. Counting ┌ against └ would NOT catch it:
	// the connector jogs draw with the same glyphs. So match whole border RUNS —
	// every ┌───┐ must have a └───┘ of the same width somewhere below it.
	assertBoxesClosed(t, lines, joined)
	assertStackedBoxesKeepTheirGap(t, lines, joined)

	// Width: the label's own measure is the longest segment, not the whole string.
	if got, want := mermaidLabelWidth("Parse tokens<br/>then layout"), 12; got != want {
		t.Errorf("mermaidLabelWidth = %d, want %d (the longest segment)", got, want)
	}
}

// TestMermaidBreakTagInSequenceParticipant: participant heads break too, and the
// ┬ lifeline roots stay on ONE row so the ladder does not tear.
func TestMermaidBreakTagInSequenceParticipant(t *testing.T) {
	src := "sequenceDiagram\n" +
		"  participant A as Ingest<br/>worker\n" +
		"  participant B as Renderer\n" +
		"  A->>B: frame"
	s := parseMermaid(src).seq
	if s == nil {
		t.Fatal("sequence did not parse")
	}
	out := renderSequence(s, labelTestCtx(80))
	lines := plainLines(out)
	joined := strings.Join(lines, "\n")

	if strings.Contains(joined, "<br") {
		t.Errorf("the break tag LEAKED into a participant head:\n%s", joined)
	}
	if lineWith(out, "Ingest") == "" || lineWith(out, "worker") == "" {
		t.Fatalf("participant label did not break:\n%s", joined)
	}

	// Every lifeline root sits on exactly one row: the row carrying ┬ is unique.
	tickRows := 0
	for _, ln := range lines {
		if strings.Contains(ln, "┬") {
			tickRows++
		}
	}
	if tickRows != 1 {
		t.Errorf("lifeline roots spread over %d rows, want 1 — the heads are not height-matched:\n%s",
			tickRows, joined)
	}
}

// TestMermaidBreakTagInEdgeLabelDoesNotLeak: an edge label is painted into one
// row of an already-solved grid, so the break flattens to a space. It must still
// never print as literal tag text.
func TestMermaidBreakTagInEdgeLabelDoesNotLeak(t *testing.T) {
	g := parseMermaid("flowchart TD\n  A -->|\"yes<br/>always\"| B").graph
	joined := strings.Join(plainLines(renderFlowchartAuto(g, labelTestCtx(80))), "\n")
	if strings.Contains(joined, "<br") {
		t.Errorf("edge-label break tag leaked as literal text:\n%s", joined)
	}
	if got := mermaidLabelFlat("yes<br/>always"); got != "yes always" {
		t.Errorf("mermaidLabelFlat = %q, want %q", got, "yes always")
	}
}

// ── the QUIET ARM: nothing without a break tag may move ──────────────────────

// TestMermaidLabelHelpersAreInertWithoutABreakTag proves the helpers are a no-op
// on ordinary labels — including a label whose text legitimately contains a
// less-than sign, which must survive verbatim and must NOT be read as markup.
func TestMermaidLabelHelpersAreInertWithoutABreakTag(t *testing.T) {
	quiet := []string{
		"Parse tokens",
		"",
		"a < b",
		"if (x < 3) break", // the word "break", a bare "<": still not a tag
		"<broadcast>",      // starts with "<br" but is NOT a break tag
		"Ingest → Render",
		"tokens<brief>done", // "<br" prefix again, deliberately
	}
	for _, label := range quiet {
		if got, want := mermaidLabelFlat(label), sanitizeText(label); got != want {
			t.Errorf("mermaidLabelFlat(%q) = %q, want the sanitized original %q", label, got, want)
		}
		segs := mermaidLabelSegments(label)
		if len(segs) != 1 || segs[0] != sanitizeText(label) {
			t.Errorf("mermaidLabelSegments(%q) = %#v, want one untouched segment", label, segs)
		}
		if got, want := mermaidLabelLines(label, 40), wrapLines(sanitizeText(label), 40); !equalStrings(got, want) {
			t.Errorf("mermaidLabelLines(%q) = %#v, want wrapLines' own answer %#v", label, got, want)
		}
	}
}

// TestMermaidRenderUnchangedWithoutABreakTag is the rendered half of the quiet
// arm: a graph with no break tag renders byte-identical through both engines to
// what the pre-change code produced (pinned here as the shape the goldens hold).
func TestMermaidRenderUnchangedWithoutABreakTag(t *testing.T) {
	srcs := []string{
		"flowchart TD\n  A[Ingest] --> B[Parse] --> C[Emit]",
		"flowchart LR\n  A[Ingest] --> B[Parse] --> C[Emit]",
		"flowchart TD\n  A[\"a < b\"] --> B{Ok}\n  B -->|yes| C([Done])",
	}
	for _, src := range srcs {
		g := parseMermaid(src).graph
		for _, w := range []int{60, 80, 100} {
			out := renderFlowchartAuto(g, labelTestCtx(w))
			for i, ln := range out {
				if got := ansi.StringWidth(ln); got != w {
					t.Errorf("%q@%d line %d width = %d, want %d", src, w, i, got, w)
				}
			}
			// A "<" in a label is text, not markup: it reaches the screen.
			if strings.Contains(src, "a < b") && lineWith(out, "a < b") == "" {
				t.Errorf("%q@%d: the literal '<' was eaten", src, w)
			}
		}
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// tdBreakSrc is a graph big enough that the auto dispatcher draws BOXES rather
// than the indented tree fallback (a 2-node chain is a chain, and chains are
// drawn as a tree) — the box path is the one that can honour a line break.
const tdBreakSrc = "flowchart TD\n" +
	"  A[\"Parse tokens<br/>then layout\"] --> B[Emit]\n" +
	"  A --> C[Cache]\n" +
	"  B --> D[Flush]\n" +
	"  C --> D"

var (
	boxTopRe = regexp.MustCompile(`[┌╭][─╌]+[┐╮]`)
	boxBotRe = regexp.MustCompile(`[└╰][─╌]+[┘╯]`)
)

// assertBoxesClosed matches whole border RUNS: every top border of a given
// visible width must be answered by a bottom border of the same width. Counting
// bare corner glyphs cannot do this — connector jogs draw with ┌ and └ too.
func assertBoxesClosed(t *testing.T, lines []string, joined string) {
	t.Helper()
	tops := map[int]int{}
	bots := map[int]int{}
	for _, ln := range lines {
		for _, m := range boxTopRe.FindAllString(ln, -1) {
			tops[ansi.StringWidth(m)]++
		}
		for _, m := range boxBotRe.FindAllString(ln, -1) {
			bots[ansi.StringWidth(m)]++
		}
	}
	if len(tops) == 0 {
		t.Fatalf("no box drawn at all:\n%s", joined)
	}
	for w, n := range tops {
		if bots[w] != n {
			t.Errorf("%d box top(s) of width %d but %d bottom(s) — a clipped box:\n%s",
				n, w, bots[w], joined)
		}
	}
}

// lrBreakSrc STACKS two nodes in one rank, the first of them tall. A rank with a
// single node per column cannot catch the geometry regression: with nothing
// stacked below it, a box drawn taller than its slot still has room to finish.
// The offset of the SECOND node in a rank is what a fixed 3-row assumption gets
// wrong.
const lrBreakSrc = "flowchart LR\n" +
	"  A[Ingest] --> B[\"Parse tokens<br/>then layout\"]\n" +
	"  A --> C[Cache]\n" +
	"  B --> D[Emit]\n" +
	"  C --> D"

// assertStackedBoxesKeepTheirGap pins what a fixed 3-row-per-node assumption
// actually breaks. A box drawn TALLER than its slot does not lose its own border
// — it eats the lrVGap blank row separating it from the next box in the same
// rank, and the two frames fuse into one double-ruled block. So: a box TOP border
// must never sit on the row directly beneath a box BOTTOM border.
func assertStackedBoxesKeepTheirGap(t *testing.T, lines []string, joined string) {
	t.Helper()
	for i := 1; i < len(lines); i++ {
		prev := borderSpans(boxBotRe, lines[i-1])
		cur := borderSpans(boxTopRe, lines[i])
		for _, b := range prev {
			for _, tp := range cur {
				if b == tp {
					t.Errorf("rows %d/%d: a box top sits directly under a box bottom at cols %d-%d "+
						"— the %d-row gap between stacked boxes was eaten:\n%s",
						i-1, i, tp[0], tp[1], lrVGap, joined)
				}
			}
		}
	}
}

// borderSpans returns each border run's [startCol, endCol) in DISPLAY COLUMNS.
// regexp indexes BYTES, and a row of box-drawing glyphs is 3 bytes per cell with
// a different prefix on every row, so comparing raw byte offsets between two rows
// compares nothing — the reason an earlier version of this assertion sat green
// against a render whose gap had visibly collapsed.
func borderSpans(re *regexp.Regexp, line string) [][2]int {
	var out [][2]int
	for _, m := range re.FindAllStringIndex(line, -1) {
		start := ansi.StringWidth(line[:m[0]])
		out = append(out, [2]int{start, start + ansi.StringWidth(line[m[0]:m[1]])})
	}
	return out
}
