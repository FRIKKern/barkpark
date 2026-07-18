package pdrender

import "strconv"

// ── footnote ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(footnote): a numbered list of notes — `notes` is a
// list of `{id, text}`. Each shown note gets a "N. " numeric marker; the `id`
// carries the article/email anchor pair (no terminal analogue — a plain ANSI
// stream has no clickable in-document links, so only the number + text
// render here). A note with no text is dropped; empty/missing `notes`
// renders nothing (honest empty state).
type footnoteRenderer struct{}

func (footnoteRenderer) Render(b Block, ctx RenderCtx) []string {
	notes, _ := b.Attrs["notes"].([]any)
	if len(notes) == 0 {
		return nil
	}
	w := clampWidth(ctx.Width)
	dim := ctx.Theme.Dim

	var out []string
	n := 0
	for _, raw := range notes {
		m, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		text := sanitizeText(attrStr(m, "text"))
		if text == "" {
			continue
		}
		n++
		out = append(out, wrapLines(dim.Render(strconv.Itoa(n)+". ")+text, w)...)
	}
	return out
}
