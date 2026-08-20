package pdrender

// ── blockquote ─────────────────────────────────────────────────────────
// Mirrors compose_block(blockquote) (compose.ex): a semantic attributed
// quotation, distinct from `pullquote`. The body reads a `content` inline
// array (else a bare `text` string), rendered italic + muted behind a left
// bar (▌ ), the same standfirst cue pullquote/ingress use since the terminal
// has no font weight to lean on. An optional `cite`/`attribution` renders as a
// dim `— Name` line under the quote. Empty body AND empty cite → nothing (an
// honest empty state, no phantom bar in the document flow).
type blockquoteRenderer struct{ ir InlineRenderer }

func (br blockquoteRenderer) Render(b Block, ctx RenderCtx) []string {
	body := br.ir.Inline(blockquoteNodes(b.Attrs), ctx)
	cite := sanitizeText(blockquoteCite(b.Attrs))
	if body == "" && cite == "" {
		return nil
	}

	const chrome = 2 // "▌ "
	inner := ctx.Width - chrome

	styled := ctx.Theme.Pullquote.Render(body)
	if inner < MinWidth {
		lines := wrapLines(styled, ctx.Width)
		if cite != "" {
			lines = append(lines, ctx.Theme.Dim.Render("— "+cite))
		}
		return lines
	}

	bar := ctx.Theme.PullquoteBar.Render("▌")
	out := make([]string, 0, 4)
	if body != "" {
		for _, line := range wrapLines(styled, inner) {
			out = append(out, bar+" "+line)
		}
	}
	if cite != "" {
		out = append(out, bar+" "+ctx.Theme.Dim.Render("— "+cite))
	}
	return out
}

// blockquoteNodes picks the quote body: a `content` inline-node array when
// present, else a bare `text` string wrapped as one node (the paragraph/heading
// authoring shape). nil → the empty state.
func blockquoteNodes(m map[string]any) []any {
	if c := attrSlice(m, "content"); len(c) > 0 {
		return c
	}
	if t := attrStr(m, "text"); t != "" {
		return []any{t}
	}
	return nil
}

// blockquoteCite reads the optional attribution — `cite` preferred, then
// `attribution`. Empty when neither is a non-blank string.
func blockquoteCite(m map[string]any) string {
	if c := attrStr(m, "cite"); c != "" {
		return c
	}
	return attrStr(m, "attribution")
}
