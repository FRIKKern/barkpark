package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── filetree ─────────────────────────────────────────────────────────────────
// The annotated file-tree block (charter D78). Contract: one `text` attr of
// VERBATIM tree lines — box glyphs (│ ├ └ ─) and indentation preserved
// exactly, never reflowed. A line's trailing annotation splits on the first
// ` ● ` / ` ○ ` / ` ✕ ` separator into a styled annotation span with the
// glyph kept IN the text stream (the glyph is the semantic carrier — NoColor
// keeps it; color is never load-bearing). An optional `legend` attr (plain
// string, e.g. "● created · ○ injected") renders as a dim legend row below —
// the self-describing block beats glyphs taught by prose.
//
// Degrade ladder: below MinWidth the chrome drops FIRST (annotation styling
// and the legend row) and the tree renders as plain preformatted text. Long
// lines cell-truncate, never re-wrap (a re-wrapped tree line breaks the box
// drawing). Empty text renders nothing (honest empty state — starter
// precedent, no phantom blank line in the document flow).
type filetreeRenderer struct{}

// filetreeGlyphs are the D78 annotation separators, in match order. The glyph
// polarity intentionally differs from the task vocabulary (● done vs ● created)
// — different domain (file-mutation provenance, D39); the in-block legend
// disambiguates locally.
var filetreeGlyphs = []string{"●", "○", "✕"}

func (filetreeRenderer) Render(b Block, ctx RenderCtx) []string {
	text := attrStr(b.Attrs, "text")

	// EMPTY-CHROME INVARIANT (blank.go): blank is `text` AND `legend`, never
	// `text` alone. This guard used to key on `text` only, so a tree whose
	// legend had been authored ahead of its lines rendered a legend row on the
	// web (`blank_filetree?/1`, #14991) and NOTHING in the terminal — the same
	// parity break in the other direction. A legend-only tree now renders its
	// legend row, and nothing else.
	if blankFiletree(b.Attrs) {
		return nil
	}
	w := clampWidth(ctx.Width)

	// Blank text with a legend must contribute NO tree rows: splitting "" would
	// hand the loop one empty line and paint a phantom blank row above the
	// legend.
	var lines []string
	if strings.TrimSpace(text) != "" {
		lines = strings.Split(strings.TrimRight(text, "\n"), "\n")
	}

	// Drop-chrome-first: too narrow for styled spans + legend — plain
	// preformatted tree, still truncated (never wrapped).
	if w < MinWidth {
		out := make([]string, 0, len(lines))
		for _, raw := range lines {
			out = append(out, truncateANSI(sanitizeText(raw), w))
		}
		return out
	}

	pal := Resolve(ctx.Theme.themeID)
	dim := ctx.Theme.Dim
	glyphStyles := map[string]lipgloss.Style{
		"●": lipgloss.NewStyle().Foreground(pal.ToneOK),
		"○": lipgloss.NewStyle().Foreground(pal.ChromeAccent),
		"✕": lipgloss.NewStyle().Foreground(pal.ToneDanger),
	}

	out := make([]string, 0, len(lines)+1)
	for _, raw := range lines {
		line := sanitizeText(raw)
		tree, glyph, note := splitTreeAnnotation(line)
		if glyph == "" {
			out = append(out, truncateANSI(tree, w))
			continue
		}
		row := tree + " " + glyphStyles[glyph].Render(glyph) + " " + dim.Render(note)
		out = append(out, truncateANSI(row, w))
	}
	if legend := sanitizeText(attrStr(b.Attrs, "legend")); legend != "" {
		out = append(out, truncateANSI(dim.Render(legend), w))
	}
	return out
}

// splitTreeAnnotation splits a tree line at its FIRST ` <glyph> ` separator
// into the verbatim tree part, the glyph, and the annotation note. A line
// without a separator returns whole with glyph "" — rendered verbatim, the
// honest no-annotation case.
func splitTreeAnnotation(line string) (tree, glyph, note string) {
	best := -1
	for _, g := range filetreeGlyphs {
		if i := strings.Index(line, " "+g+" "); i >= 0 && (best < 0 || i < best) {
			best = i
			glyph = g
		}
	}
	if best < 0 {
		return line, "", ""
	}
	tree = line[:best]
	note = strings.TrimPrefix(line[best:], " "+glyph+" ")
	return tree, glyph, note
}
