package pdrender

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The Go (TUI) leg of the code-block LINE-EMPHASIS parity lock
// (pe-bl-code-emphasis).
//
// It reads THE SAME FILE the Elixir and JS legs read — not a mirror, the same
// file: api/test/support/fixtures/code-block-emphasis-parity.json. Each engine
// derives its own rendering from the fixture's `line_tones`, so the three
// surfaces can disagree about how a tone LOOKS but never about which line
// carries it.
//
// The TUI's channel is the 2-cell gutter: the bar glyph plus a tone SIGIL in
// place of the separator space (comment '~', offending '-', fixed '+'). This
// leg runs at Profile=NoColor ON PURPOSE — lipgloss emits no escapes there, so
// the only thing that can carry the emphasis is the sigil. A version that had
// coloured the bar and left the separator alone would pass a colour-profile test
// and lose the whole channel on a NoColor terminal; this test cannot.
//
// MUTATION PROOF: drop the emphasis arm in codeRenderer.render (always emit
// bar+" "+line) and TestCodeBlockEmphasisParity reds on every case carrying a
// live range; make codeEmphasis accept a numeric STRING (use attrInt instead of
// emphasisLine) and the "malformed range is DROPPED" case reds.

const codeEmphasisFixture = "../../api/test/support/fixtures/code-block-emphasis-parity.json"

type codeEmphasisCase struct {
	Name      string         `json:"name"`
	Block     map[string]any `json:"block"`
	LineTones []*string      `json:"line_tones"`
}

type codeEmphasisDoc struct {
	Tones           []string           `json:"tones"`
	Sigils          map[string]string  `json:"sigils"`
	SpanClassPrefix string             `json:"span_class_prefix"`
	Source          string             `json:"source"`
	Cases           []codeEmphasisCase `json:"cases"`
}

func loadCodeEmphasisDoc(t *testing.T) codeEmphasisDoc {
	t.Helper()
	raw, err := os.ReadFile(filepath.FromSlash(codeEmphasisFixture))
	if err != nil {
		t.Fatalf("shared code-emphasis fixture unreadable (%s): %v — "+
			"the Elixir and JS legs read the same file", codeEmphasisFixture, err)
	}
	var doc codeEmphasisDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("shared code-emphasis fixture is not valid JSON: %v", err)
	}
	return doc
}

// The vocabulary contract itself, asserted against the shared fixture, so a
// rename of a tone reds all three legs at once.
func TestCodeBlockEmphasisContractVocabulary(t *testing.T) {
	doc := loadCodeEmphasisDoc(t)
	want := []string{"comment", "offending", "fixed"}
	if strings.Join(doc.Tones, ",") != strings.Join(want, ",") {
		t.Errorf("the code-emphasis tone vocabulary is %v; fixture says %v", want, doc.Tones)
	}
	// The fixture's sigil table and the renderer's must be the same table.
	for tone, sigil := range doc.Sigils {
		if tone == "none" {
			if sigil != " " {
				t.Errorf("the un-emphasized gutter separator is a space; fixture says %q", sigil)
			}
			continue
		}
		if emphasisSigil[tone] != sigil {
			t.Errorf("tone %q: fixture sigil %q, renderer sigil %q", tone, sigil, emphasisSigil[tone])
		}
	}
	if len(emphasisSigil) != len(doc.Tones) {
		t.Errorf("the renderer knows %d tones, the fixture names %d", len(emphasisSigil), len(doc.Tones))
	}
	if len(doc.Cases) < 7 {
		t.Fatalf("the shared fixture must keep its coverage, got %d cases", len(doc.Cases))
	}
}

func TestCodeBlockEmphasisParity(t *testing.T) {
	doc := loadCodeEmphasisDoc(t)
	// NoColor: no lipgloss escapes at all, so the sigil is the ONLY channel left.
	// Wide enough that no line truncates.
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}
	sourceLines := strings.Split(doc.Source, "\n")

	for _, c := range doc.Cases {
		c := c
		t.Run(c.Name, func(t *testing.T) {
			if len(c.LineTones) != len(sourceLines) {
				t.Fatalf("case %q: line_tones has %d entries for %d source lines",
					c.Name, len(c.LineTones), len(sourceLines))
			}
			cr := newCodeRenderer()
			rendered := cr.Render(Block{Type: "code", Attrs: c.Block}, ctx)
			if len(rendered) == 0 {
				t.Fatalf("case %q: expected content, got an EMPTY render", c.Name)
			}
			out := ansi.Strip(strings.Join(rendered, "\n"))

			for i, src := range sourceLines {
				if src == "" {
					continue // the trailing-newline segment renders no line
				}
				gutter := gutterFor(t, c.Name, out, src)
				want := "▌" + " "
				if c.LineTones[i] != nil {
					want = "▌" + doc.Sigils[*c.LineTones[i]]
				}
				if gutter != want {
					tone := "none"
					if c.LineTones[i] != nil {
						tone = *c.LineTones[i]
					}
					t.Errorf("case %q line %d (%q, tone %s): gutter %q, want %q\nfull render:\n%s",
						c.Name, i+1, src, tone, gutter, want, out)
				}
			}
		})
	}
}

// gutterFor finds the rendered line carrying src and returns its two gutter
// cells. Source lines are unique per the fixture, so the match is unambiguous.
func gutterFor(t *testing.T, caseName, out, src string) string {
	t.Helper()
	for _, line := range strings.Split(out, "\n") {
		if idx := strings.Index(line, src); idx >= 0 {
			if idx < 2 {
				t.Fatalf("case %q: line %q has no 2-cell gutter before %q", caseName, line, src)
			}
			return string([]rune(line)[:2])
		}
	}
	t.Fatalf("case %q: source line %q never appeared in the render:\n%s", caseName, src, out)
	return ""
}

// The control the per-case loop needs: a live range must actually MOVE the
// render away from the no-emphasis one. Without this, a renderer that ignored
// `emphasis` entirely would still pass every "tone is nil → gutter is a space"
// assertion above for the three all-null cases.
func TestCodeBlockEmphasisChangesTheRender(t *testing.T) {
	doc := loadCodeEmphasisDoc(t)
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}

	plain := strings.Join(newCodeRenderer().Render(
		Block{Type: "code", Attrs: doc.Cases[0].Block}, ctx), "\n")

	for i, c := range doc.Cases {
		live := false
		for _, tone := range c.LineTones {
			if tone != nil {
				live = true
				break
			}
		}
		got := strings.Join(newCodeRenderer().Render(Block{Type: "code", Attrs: c.Block}, ctx), "\n")
		if live && got == plain {
			t.Errorf("case %d (%q) carries a live range but rendered identically to the "+
				"no-emphasis block — the TUI leg is not reading `emphasis`", i, c.Name)
		}
		if !live && got != plain {
			t.Errorf("case %d (%q) has no live range but diverged from the no-emphasis block:\n%q",
				i, c.Name, got)
		}
	}
}

// The memo cache is keyed by content; emphasis is part of that content. Two
// blocks with the same source and lang but different emphasis must not share a
// cached render.
func TestCodeBlockEmphasisIsInTheMemoKey(t *testing.T) {
	doc := loadCodeEmphasisDoc(t)
	ctx := RenderCtx{Width: 100, Theme: DarkTheme(), Profile: NoColor}
	cr := newCodeRenderer()

	first := strings.Join(cr.Render(Block{Type: "code", Attrs: doc.Cases[0].Block}, ctx), "\n")
	second := strings.Join(cr.Render(Block{Type: "code", Attrs: doc.Cases[2].Block}, ctx), "\n")

	if first == second {
		t.Fatalf("the same codeRenderer served the emphasis-bearing block the plain block's "+
			"cached lines — emphasis is missing from codeKey.hash:\n%q", second)
	}
}
