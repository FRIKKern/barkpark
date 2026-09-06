package pdrender

import (
	"math"
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
	kind := sanitizeText(strings.TrimSpace(stageFieldText(b.Attrs, "kind")))
	title := sanitizeText(strings.TrimSpace(stageFieldText(b.Attrs, "title")))
	detail := sanitizeText(strings.TrimSpace(stageFieldText(b.Attrs, "detail")))
	files := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "files")))

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
	// `source` coercion (RATIFIED): read the RAW attr and type-switch BEFORE any
	// stringify (attrStr/toStr would render a bool `true`/`false` as the literal
	// text "true"/"false" — the leak this fixes). A boolean `true` → an ORIGIN
	// marker via the Eyebrow theme (◆ ORIGIN, the TUI-native origin signal, mirrors
	// the reader's bp-pnode--src accent — no new token); a non-empty STRING → the
	// provenance line rendering the text; `false`/absent → nothing.
	switch raw := b.Attrs["source"].(type) {
	case bool:
		if raw {
			out = append(out, wrapLines(ctx.Theme.Eyebrow.Render("◆ ORIGIN"), w)...)
		}
	case string:
		if s := sanitizeText(strings.TrimSpace(raw)); s != "" {
			out = append(out, wrapLines(ctx.Theme.Dim.Render("source: "+s), w)...)
		}
	}
	if len(out) == 0 {
		return []string{""}
	}
	return out
}

// Stage text is slot-first, matching PortableDoc.Slots.stage_field_text/2.
// A materialized empty slot suppresses the flat shadow; malformed/non-list
// slots fall back to the legacy scalar carrier. Rendering never rewrites either.
func stageFieldText(attrs map[string]any, field string) string {
	if slots, ok := attrs["slots"].(map[string]any); ok {
		if elements, ok := slots[field].([]any); ok {
			if len(elements) > 0 {
				if element, ok := elements[0].(map[string]any); ok {
					return stageInlineText(element["content"])
				}
			}
			return ""
		}
	}
	return stageScalarText(attrs[field])
}

func stageInlineText(raw any) string {
	switch value := raw.(type) {
	case string:
		return value
	case []any:
		var out strings.Builder
		for _, rawNode := range value {
			switch node := rawNode.(type) {
			case string:
				out.WriteString(node)
			case map[string]any:
				if node["type"] == "text" || node["type"] == "code" {
					out.WriteString(stageScalarText(node["value"]))
				} else if children, ok := node["children"].([]any); ok {
					out.WriteString(stageInlineText(children))
				}
			}
		}
		return out.String()
	}
	return ""
}

func stageScalarText(value any) string {
	switch number := value.(type) {
	case string, int, int64:
		return toStr(value)
	case float64:
		if !math.IsInf(number, 0) && number == math.Trunc(number) {
			return toStr(number)
		}
	}
	return ""
}

// ── card ─────────────────────────────────────────────────────────────────────
// A rounded-border box holding up to four named slots rendered in model-B order:
// media, title, body, action. Each slot's element blocks render straight through
// the registry with NO per-slot label chrome (model B, #1529, dropped the muted
// `media`/`action` caption lines). A slot value is either a single block map or
// an array of block maps (element blocks like paragraph/heading), recursed via
// reg.Render at the box's inner width. The MEDIA slot additionally fast-paths
// imagery: a typed `type:"image"` child renders as the image box, and a typeless
// `{src,alt}` media element is coerced to `type:"image"` (the Elixir
// normalize_media_element seam, components.ex) so it fast-paths instead of
// degrading to the unknown-block box. The border foreground is tinted by the
// card's flat `tone` (info|ok|warn|danger); missing/other → today's neutral rule
// color. Below MinWidth the border is dropped and the slots render flat. No
// non-empty slot → one blank line. The card holds a Registry back-reference (like
// section / figure) so arbitrary slot content nests without a retained tree.
type cardRenderer struct{ reg *Registry }

func (cr cardRenderer) Render(b Block, ctx RenderCtx) []string {
	slots := cardSlots(b.Attrs)
	tone := attrStr(b.Attrs, "tone")

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome
	flat := inner < MinWidth
	childWidth := inner
	if flat {
		childWidth = ctx.Width
	}
	childCtx := ctx.Deeper().WithWidth(clampWidth(childWidth))

	var lines []string
	renderSlot := func(key string, coerceImage bool) {
		blocks := slotBlocks(slots[key])
		if coerceImage {
			coerceMediaImages(blocks)
		}
		for _, blk := range blocks {
			lines = append(lines, cr.reg.Render(blk, childCtx)...)
		}
	}
	// Model-B slot order (components.ex:355-358; portable-doc.tsx:934): media
	// first, then title, body, action. No label chrome on any slot.
	renderSlot("media", true)
	renderSlot("title", false)
	renderSlot("body", false)
	renderSlot("action", false)

	if len(lines) == 0 {
		return []string{""}
	}
	if flat {
		return lines
	}

	body := lipgloss.JoinVertical(lipgloss.Left, lines...)
	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cardToneColor(ctx.Theme, tone)).
		Padding(0, 1).
		// lipgloss Width INCLUDES the padding (border excluded): inner+2 gives the
		// children their full `inner` columns and lands the border on ctx.Width.
		// Width(inner) left inner-2 for content, force-wrapping bordered children.
		Width(clampWidth(inner + 2)).
		Render(body)
	return strings.Split(card, "\n")
}

// coerceMediaImages implements the Elixir normalize_media_element seam
// (components.ex:386-388) for the terminal: a media-slot child that is a bare
// `{src,alt}` element with no explicit `type` is retyped to "image" so the
// registry routes it to imageRenderer's fast-path box instead of degrading to
// the unknown-block fallback. Typed children (including an explicit
// `type:"image"`) are left untouched. Scoped to the MEDIA slot only — never a
// global coercion. Mutates in place (blocks are freshly decoded per render).
func coerceMediaImages(blocks []Block) {
	for i := range blocks {
		if blocks[i].Type != "" {
			continue
		}
		if _, ok := blocks[i].Attrs["src"]; ok {
			blocks[i].Type = "image"
			blocks[i].Attrs["type"] = "image"
		}
	}
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
