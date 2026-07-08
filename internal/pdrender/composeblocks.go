package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── composition widgets: note / stage / card ────────────────────────────────
//
// These three blocks are the terminal counterparts of the PortableDoc
// composition widgets the web/Studio reader gained in the "everything editable"
// / composition-doctrine work (note + stage + card). Before this file existed
// they fell through to the "unknown block" fallback box in the TUI/CLI while the
// web reader rendered them fully — a cross-surface divergence this closes
// (pdrender-block-parity: pbp-note / pbp-stage / pbp-card).
//
// Import discipline holds: only lipgloss + the stdlib, styles come from the
// injected Theme, every document-controlled string passes through sanitizeText
// before display, and each renderer degrades (never panics) on empty attrs,
// empty slots, or a sub-MinWidth column.

// ── note ─────────────────────────────────────────────────────────────────────
// A muted left-bar (▌) "definition row": an optional label chip, a bold `lead`
// run-in, and the wrapped `text` body — composed into one string and bar-
// prefixed on every wrapped line (the callout/pullquote idiom). Below MinWidth
// the bar is dropped and the row renders flat. All-empty attrs → one blank line.
type noteRenderer struct{}

func (noteRenderer) Render(b Block, ctx RenderCtx) []string {
	label := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "label")))
	lead := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "lead")))
	text := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "text")))

	if label == "" && lead == "" && text == "" {
		return []string{""}
	}

	// Compose the definition row: label chip (muted bold) · bold lead run-in ·
	// plain text body. A double space sets the chip off; a single space joins
	// the lead run-in to the body.
	var body strings.Builder
	if label != "" {
		body.WriteString(ctx.Theme.FieldLabel.Render(label))
		if lead != "" || text != "" {
			body.WriteString("  ")
		}
	}
	if lead != "" {
		body.WriteString(ctx.Theme.Body.Bold(true).Render(lead))
		if text != "" {
			body.WriteString(" ")
		}
	}
	if text != "" {
		body.WriteString(ctx.Theme.Body.Render(text))
	}
	composed := body.String()

	const chrome = 2 // "▌ " bar + space
	inner := ctx.Width - chrome
	if inner < MinWidth {
		// Narrow: drop the bar, render the row flat at full width.
		return wrapLines(composed, ctx.Width)
	}

	bar := ctx.Theme.Dim.Render("▌")
	wrapped := wrapLines(composed, inner)
	out := make([]string, 0, len(wrapped))
	for _, line := range wrapped {
		out = append(out, bar+" "+line)
	}
	return out
}

// ── stage ────────────────────────────────────────────────────────────────────
// A stacked "cell": an UPPERCASE `kind` kicker (accent, the eyebrow idiom), a
// bold `title`, a dim `detail`, then optional dim `files:`/`source:` provenance
// lines. Every line wraps to the full column — no box, no bar (the stack IS the
// widget). Omitted fields are skipped; all-empty attrs → one blank line.
type stageRenderer struct{}

func (stageRenderer) Render(b Block, ctx RenderCtx) []string {
	kind := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "kind")))
	title := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "title")))
	detail := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "detail")))
	files := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "files")))
	source := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "source")))

	w := clampWidth(ctx.Width)
	var out []string
	if kind != "" {
		out = append(out, wrapLines(ctx.Theme.Eyebrow.Render(strings.ToUpper(kind)), w)...)
	}
	if title != "" {
		out = append(out, wrapLines(ctx.Theme.Body.Bold(true).Render(title), w)...)
	}
	if detail != "" {
		out = append(out, wrapLines(ctx.Theme.Dim.Render(detail), w)...)
	}
	if files != "" {
		out = append(out, wrapLines(ctx.Theme.Dim.Render("files: "+files), w)...)
	}
	if source != "" {
		out = append(out, wrapLines(ctx.Theme.Dim.Render("source: "+source), w)...)
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// ── card ─────────────────────────────────────────────────────────────────────
// A rounded-border box holding up to four named slots. `title` and `body` slots
// stack (their element blocks render straight through the registry); `media` and
// `action` slots get a muted label line above their recursed content. Each slot
// value is either a single block map or an array of block maps (element blocks
// like paragraph/heading), recursed via reg.Render at the box's inner width.
// Below MinWidth the border is dropped and the slots render flat. No non-empty
// slot → one blank line. The card holds a Registry back-reference (like section
// / figure) so arbitrary slot content nests without a retained tree.
type cardRenderer struct{ reg *Registry }

func (cr cardRenderer) Render(b Block, ctx RenderCtx) []string {
	slots := cardSlots(b.Attrs)

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome
	flat := inner < MinWidth
	childWidth := inner
	if flat {
		childWidth = ctx.Width
	}
	childCtx := ctx.Deeper().WithWidth(clampWidth(childWidth))

	var lines []string
	renderSlot := func(key, label string) {
		blocks := slotBlocks(slots[key])
		if len(blocks) == 0 {
			return
		}
		if label != "" {
			lines = append(lines, childCtx.Theme.FieldLabel.Render(label))
		}
		for _, blk := range blocks {
			lines = append(lines, cr.reg.Render(blk, childCtx)...)
		}
	}
	renderSlot("title", "")
	renderSlot("body", "")
	renderSlot("media", "media")
	renderSlot("action", "action")

	if len(lines) == 0 {
		return []string{""}
	}
	if flat {
		return lines
	}

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		Width(clampWidth(inner)).
		Render(body)
	return strings.Split(card, "\n")
}

// cardSlots reads the `slots` object off a card block. Missing/wrong-typed →
// an empty map so every slot read is a clean miss.
func cardSlots(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	if s, ok := m["slots"].(map[string]any); ok {
		return s
	}
	return map[string]any{}
}

// slotBlocks normalizes a slot value to a []Block: an array of block maps, or a
// single block map (mirrors the "slots accept []any or single map" tolerance).
// Bare scalars / nil → nil (an empty slot). Reuses the decoder's blockFromMap so
// nested section/figure children inside a slot still recurse.
func slotBlocks(raw any) []Block {
	switch v := raw.(type) {
	case []any:
		return decodeAnyBlocks(v, 0)
	case map[string]any:
		return []Block{blockFromMap(v, 0)}
	default:
		return nil
	}
}
