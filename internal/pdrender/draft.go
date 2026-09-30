package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── DRAFT marker (PDS-D749: a draft row is visibly labelled on every reader) ──
//
// The third painter of the task-snapshot draft marker: the Phoenix View
// (components.ex draft_html/1 → <span class="bp-draft">DRAFT</span>) and
// @barkpark/react (inline.tsx draftHtml) paint it before the title of a
// task-board card, a tasks/task-list row and a roadmap lane; this is the
// terminal/wasm reader of the same paper blocks.

// draftLabel is the DRAFT word the readers share. The hue is the `blocked` amber
// (Callout "warning") — the TUI board's draftChip hue — so a draft reads "not the
// real row yet", not an error.
const draftLabel = "DRAFT"

// isDraftRow mirrors draft_html/1's `get(r, "draft") == true`: only a JSON
// boolean true marks a row, so an absent/false/"true"-string key paints nothing.
func isDraftRow(r map[string]any) bool { return attrBool(r, "draft") }

// draftTitle prefixes a draft row's already-styled title with the amber DRAFT
// chip. It rides the TITLE (as internal/taskboard draftMark does) rather than the
// trailing meta, because the meta sheds at narrow widths and a marker that sheds
// is a marker that lies. A non-draft row's title is returned VERBATIM, so a
// snapshot without the key renders byte-identical to the pre-marker reader.
func draftTitle(r map[string]any, ctx RenderCtx, styledTitle string) string {
	if !isDraftRow(r) {
		return styledTitle
	}
	return statusGlyphStyle(ctx.Theme, "blocked").Render(draftLabel) + " " + styledTitle
}

// draftLabelWidth is the visible width the DRAFT chip adds before a draft row's
// title (0 for a published row) — for readers that size a fixed label column.
func draftLabelWidth(r map[string]any) int {
	if !isDraftRow(r) {
		return 0
	}
	return runeWidth(draftLabel) + 1
}

// draftFitLabel renders a fixed-width label cell (roadmap lane label, tree row
// title): the plain `DRAFT title` text is padded/truncated to w FIRST (so the
// visible budget stays exact), then the chip portion is painted amber and the
// rest in style. At a width too narrow to hold `DRAFT ` whole, the truncated
// remnant is painted amber in full — the marker clips, it never disappears. A
// non-draft row renders exactly as the pre-marker style.Render(padOrTruncate(…)).
func draftFitLabel(r map[string]any, ctx RenderCtx, title string, w int, style lipgloss.Style) string {
	if !isDraftRow(r) {
		return style.Render(padOrTruncate(title, w))
	}
	chip := statusGlyphStyle(ctx.Theme, "blocked")
	fitted := padOrTruncate(draftLabel+" "+title, w)
	if rest, ok := strings.CutPrefix(fitted, draftLabel+" "); ok {
		return chip.Render(draftLabel) + " " + style.Render(rest)
	}
	return chip.Render(fitted)
}
