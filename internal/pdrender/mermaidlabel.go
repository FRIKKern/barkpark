package pdrender

import (
	"regexp"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── mermaid label line breaks ────────────────────────────────────────────────
//
// Mermaid's ONLY way to say "break this label here" is an HTML break tag inside
// the label text: A["Parse tokens<br/>then layout"]. It is not decoration — it
// is a LAYOUT instruction, and it has to be spent as a line break rather than as
// label width, or the box is measured from one long string and wraps at an
// arbitrary column mid-phrase while the tag itself prints as literal text.
//
// WHY NOT sanitizeText. The obvious fix — rewrite the tag to "\n" at parse time
// — silently does the WRONG thing here: sanitizeText strips every rune below
// 0x20, newline included (isCtrlRune, inline.go), so the break would be deleted
// and the two lines welded into "Parse tokensthen layout". Every mermaid label
// is sanitized on its way to the screen, so the split has to happen BEFORE the
// sanitize, per segment. That is what these helpers do, and it is why they are
// mermaid-local instead of a change to the repo-wide sanitizeText: a break tag
// is mermaid grammar, and ~200 non-mermaid call sites have no business growing
// an opinion about it.
//
// TWO SHAPES, ON PURPOSE. A node box already paints N rows, so it honours the
// break (mmLabelLines / mmLabelWidth). An EDGE label, a sequence message and the
// heuristics' one-line relation summary are painted into a single row of an
// already-solved grid, where a second line has nowhere to go; those flatten the
// tag to a single space (mmLabelFlat). Flattening still fixes the leak and the
// width — it just spends the break as a word gap instead of a row.

// mermaidBreakRe matches Mermaid's label line-break tag in every spelling it
// accepts: <br>, <br/>, <br />, <BR/>, and the space-padded variants.
var mermaidBreakRe = regexp.MustCompile(`(?i)<br\s*/?>`)

// mermaidLabelSegments splits a label on its break tags into the author's
// intended lines, sanitizing each one. Segments that are empty after trimming
// are dropped, so a trailing "<br/>" does not open a blank row. Never returns
// an empty slice: a label that is nothing but break tags yields one "".
func mermaidLabelSegments(label string) []string {
	if !mermaidBreakRe.MatchString(label) {
		return []string{sanitizeText(label)}
	}
	parts := mermaidBreakRe.Split(label, -1)
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(sanitizeText(p))
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// mermaidLabelLines is wrapLines for a label that may carry break tags: it
// splits on the author's breaks FIRST, then word-wraps each segment to width, so
// a hard break is always honoured and only the overflow inside a segment wraps.
func mermaidLabelLines(label string, width int) []string {
	segs := mermaidLabelSegments(label)
	if len(segs) == 1 {
		return wrapLines(segs[0], width)
	}
	out := make([]string, 0, len(segs))
	for _, seg := range segs {
		out = append(out, wrapLines(seg, width)...)
	}
	return out
}

// mermaidLabelWidth is the visible width a label NEEDS: the widest of its
// segments, not the width of the whole string with the tags counted in. This is
// the number a box-sizing solver must read — measuring the unsplit string makes
// every broken label demand a box it will never fill.
func mermaidLabelWidth(label string) int {
	w := 0
	for _, seg := range mermaidLabelSegments(label) {
		if sw := lipgloss.Width(seg); sw > w {
			w = sw
		}
	}
	return w
}

// mermaidLabelFlat is the single-row form: break tags become one space, so the
// tag never prints literally and the width is honest, in the places that cannot
// grow a second row (edge labels, sequence messages, the heuristics summary).
func mermaidLabelFlat(label string) string {
	if !mermaidBreakRe.MatchString(label) {
		return sanitizeText(label)
	}
	return strings.TrimSpace(strings.Join(mermaidLabelSegments(label), " "))
}
