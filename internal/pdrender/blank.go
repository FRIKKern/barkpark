package pdrender

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// ── the empty-chrome invariant ──────────────────────────────────────────────
// The Go mirror of the Elixir composer's blank-block guards, so the TUI and the
// web reader agree on what a blank block IS. The canonical rule lives in
// api/lib/barkpark/portable_doc/render/compose.ex:
//
//	defp blank_field?(b, key),
//	  do: b |> Map.get(key, "") |> stringish() |> String.trim() == ""
//
//	defp blank_diagram?(b),   do: blank_field?(b, "source") and blank_field?(b, "caption")
//	defp blank_asciicast?(b), do: blank_field?(b, "src")    and blank_field?(b, "caption")
//	defp blank_action?(b),    do: blank_field?(b, "label")  and blank_field?(b, "href")
//	defp blank_filetree?(b),  do: blank_field?(b, "text")   and blank_field?(b, "legend")
//
// (`blank_field?/2` was extracted from `blank_code_source?/1` in #14806 and the
// four type predicates added in #14991; `figure` is decided in `figure_html/3`,
// see blankFigure below.)
//
// EACH PREDICATE IS AN AND OVER EVERY FIELD A READER COULD SEE, NEVER AN OR —
// the guard may only remove a block from which nothing authored survives.
// Dropping a caption because its media is missing would DELETE prose. Chrome-only
// keys are excluded by construction: `priority` on an action is a button skin,
// `poster`/`rows` on an asciicast are player options for a recording that is not
// there, so a priority-only or poster-only block is still blank.

// stringishAttr is the Go twin of compose.ex's `stringish/1`: a binary passes
// through, nil is "", a number/boolean (Elixir: `is_number(v) or is_atom(v)`)
// prints, and EVERYTHING ELSE — a map, a list, any non-scalar the wire should
// never have put in a string field — degrades to "" rather than to its Go `%v`
// spelling. That last clause is the one place this differs from the package's
// general attrStr: `attrStr(m, "value")` on a map answers "map[]", which would
// read as CONTENT here, while compose.ex's `stringish(_), do: ""` calls it blank
// (pinned by render_test.exs's "a non-stringish (map) value" case).
func stringishAttr(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	switch v := m[key].(type) {
	case nil:
		return ""
	case string:
		return v
	case bool, float64, int, int64:
		return toStr(v)
	default:
		return ""
	}
}

// blankAttr is THE ONE blank-field reader every guard below shares, so no two
// block types can drift apart on what "blank" means — the mirror of
// `blank_field?/2`.
//
// WHICH WHITESPACE COUNTS: Go's strings.TrimSpace strips unicode.IsSpace, and
// Elixir's String.trim/1 strips the Unicode White_Space set. Both cover ASCII
// space/tab/newline/CR/VT/FF, NEL U+0085, NBSP U+00A0, OGHAM SPACE U+1680, the
// U+2000–200A quads, LINE/PARAGRAPH SEPARATOR U+2028/U+2029, NARROW NBSP
// U+202F, MEDIUM MATHEMATICAL SPACE U+205F and IDEOGRAPHIC SPACE U+3000 — so a
// whitespace-only field is blank whatever the author pasted. Zero-width
// characters (ZWSP U+200B, BOM U+FEFF) are NOT White_Space in either language
// and stay CONTENT: they are typed glyphs, not layout, and the guard must not
// over-reach.
func blankAttr(m map[string]any, key string) bool {
	return strings.TrimSpace(stringishAttr(m, key)) == ""
}

// blankDiagram mirrors compose.ex `blank_diagram?/1`. A diagram carrying EITHER
// a Mermaid source or a caption renders unchanged.
func blankDiagram(m map[string]any) bool {
	return blankAttr(m, "source") && blankAttr(m, "caption")
}

// blankAsciicast mirrors compose.ex `blank_asciicast?/1`. `poster` and `rows`
// are PLAYER OPTIONS, not content — a poster names a frame of a recording that
// is not there — so a poster/rows/duration-only block is still blank even
// though asciicastMeta could spell a suffix out of it.
func blankAsciicast(m map[string]any) bool {
	return blankAttr(m, "src") && blankAttr(m, "caption")
}

// blankAction mirrors compose.ex `blank_action?/1`. Keyed on the RAW href the
// author wrote, not on sanitizeURL's verdict, exactly as the Elixir clause is
// keyed on the raw field and not on `safe_url/1` — a link the sanitizer refuses
// is still an authored destination, and the two surfaces must agree on the
// block's existence before they disagree about its safety. `priority` is chrome.
func blankAction(m map[string]any) bool {
	return blankAttr(m, "label") && blankAttr(m, "href")
}

// blankFiletree mirrors compose.ex `blank_filetree?/1`.
//
// NOTE THE WIDENING: this renderer already returned nil for a blank `text`, but
// on `text` ALONE — so a tree whose legend had been authored ahead of its lines
// rendered a legend row on the web and NOTHING in the terminal. The AND is the
// mirror: legend-only is not blank, and the legend row stands.
func blankFiletree(m map[string]any) bool {
	return blankAttr(m, "text") && blankAttr(m, "legend")
}

// blankFigure mirrors compose.ex's figure guard, which lives in `figure_html/3`
// rather than in a `blank_*?/1` predicate because the decision needs the CHILD'S
// COMPOSED BYTES, not a key:
//
//	if String.trim(stringish(child_html)) == "" and String.trim(caption) == "",
//	  do: "", else: figure_frame_html(child_html, caption, style)
//
// That is deliberately STRONGER than a key check: a missing/nil/non-map child
// composes to "", and so does a child that is itself scaffolding — an asset-less
// image, or (since #14806) a sourceless code block — so a figure wrapping a
// nothing-child is blank too. The Go twin asks the same question of the RENDERED
// child: ANSI is stripped first so a styled-but-empty child cannot smuggle escape
// bytes past the trim. EITHER half alone keeps the frame.
func blankFigure(m map[string]any, childLines []string) bool {
	return strings.TrimSpace(ansi.Strip(strings.Join(childLines, "\n"))) == "" &&
		blankAttr(m, "caption")
}
