package pdrender

// ── diff ─────────────────────────────────────────────────────────
// Mirrors compose_block(diff) (compose.ex): the starter render is
// the block's `text` attr, sanitized and width-wrapped. Empty text renders
// nothing (honest empty state — no phantom blank line in the document flow).
// Grow this into the block's real terminal form; eyebrowRenderer
// (richblocks.go) shows themed styling, gaugelist.go a full data block.
type diffRenderer struct{}

func (diffRenderer) Render(b Block, ctx RenderCtx) []string {
	text := sanitizeText(attrStr(b.Attrs, "text"))
	if text == "" {
		return nil
	}
	return wrapLines(text, ctx.Width)
}
