package pdrender

import (
	"fmt"
	"strings"
)

// Inline renders a run of inline nodes to ONE styled ANSI string (no wrapping).
// It is a faithful port of compose_inline/2 + apply_marks/3 in render.ex:
//
//   - text (+ marks bold/italic/underline/strike/code/link) — marks applied
//     RIGHT-TO-LEFT so the FIRST mark in the list ends up OUTERMOST (matches
//     ProseMirror's serializer order, and the Elixir Enum.reverse |> reduce).
//   - strong / em — recurse into children, wrap bold / italic.
//   - code — a leaf inline chip (subtle bg + the theme's InlineCode style).
//   - link — NON-recursive: a link nested in a link flattens to plain text.
//   - bare strings / numbers — coerced to a text node (compose_inline tolerance).
//
// The block renderer then word-wraps the returned string to its known width.
func (ir InlineRenderer) Inline(nodes []any, ctx RenderCtx) string {
	var b strings.Builder
	for _, n := range nodes {
		b.WriteString(ir.node(n, ctx, false))
	}
	return b.String()
}

// node renders a single inline node. insideLink tracks whether we are already
// within a link so a nested link can flatten (the model keeps links
// non-recursive).
func (ir InlineRenderer) node(n any, ctx RenderCtx, insideLink bool) string {
	switch v := n.(type) {
	case string:
		// Bare string → a text node with no marks.
		return v
	case float64, int, int64, bool:
		return toStr(v)
	case fmt.Stringer:
		return v.String()
	case map[string]any:
		return ir.typed(v, ctx, insideLink)
	default:
		return ""
	}
}

// typed dispatches a map-shaped inline node by its "type" discriminator.
func (ir InlineRenderer) typed(n map[string]any, ctx RenderCtx, insideLink bool) string {
	switch attrStr(n, "type") {
	case "text":
		value := attrStr(n, "value")
		marks := attrSlice(n, "marks")
		if len(marks) == 0 {
			return value
		}
		return ir.applyMarks(value, marks, ctx, insideLink)

	case "strong":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("bold").Render(inner)

	case "em":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("italic").Render(inner)

	case "underline":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("underline").Render(inner)

	case "strikethrough", "strike", "s":
		inner := ir.children(n, ctx, insideLink)
		return ir.theme.markStyle("strikethrough").Render(inner)

	case "code":
		return ir.theme.InlineCode.Render(attrStr(n, "value"))

	case "link":
		// Children are rendered with insideLink=true so a nested link flattens.
		inner := ir.children(n, ctx, true)
		if insideLink {
			// Nested link → plain (already-styled) text, no new link chrome.
			return inner
		}
		return ir.renderLink(attrStr(n, "href"), inner, ctx)

	case "wikilink":
		// Unresolved internal link — no href yet. Render the label (children)
		// in the link style; a resolver task adds navigation later.
		return ir.theme.Link.Render(ir.children(n, ctx, insideLink))

	case "blockref":
		// Leaf — the "^anchor" pointer token, dimmed.
		return ir.theme.Dim.Render("^" + attrStr(n, "anchor"))

	case "tag":
		// Leaf — the "#name" token, link-styled.
		return ir.theme.Link.Render("#" + attrStr(n, "name"))

	default:
		// Unknown inline type → render its children if any, else nothing.
		// (compose_inline raises here; we degrade gracefully like the block path.)
		if _, ok := n["children"]; ok {
			return ir.children(n, ctx, insideLink)
		}
		return ""
	}
}

// children renders an inline node's "children" array in order.
func (ir InlineRenderer) children(n map[string]any, ctx RenderCtx, insideLink bool) string {
	var b strings.Builder
	for _, c := range attrSlice(n, "children") {
		b.WriteString(ir.node(c, ctx, insideLink))
	}
	return b.String()
}

// applyMarks folds a ProseMirror-style mark list RIGHT-TO-LEFT around a text
// leaf, so the first mark in the list is the OUTERMOST wrapper. Direct port of
// apply_marks/3 + apply_mark/3 in render.ex.
//
// In a terminal we cannot nest <span> tags; instead each mark contributes its
// styling attribute to a single lipgloss.Style, accumulated, then applied once.
// The link mark is the exception — it wraps the styled text in OSC 8 chrome (or
// a dim suffix), and it is non-recursive, so once a link mark is seen the
// remaining (outer) marks still style the visible text but cannot re-link it.
func (ir InlineRenderer) applyMarks(value string, marks []any, ctx RenderCtx, insideLink bool) string {
	style := ir.theme.Body
	codeChip := false
	var linkHref string
	hasLink := false

	// Walk marks right-to-left so the first mark wins on conflicts and lands
	// as the conceptual outermost wrapper. For flat lipgloss styling the order
	// only matters for the link decision, which we resolve below.
	for i := len(marks) - 1; i >= 0; i-- {
		mt := markType(marks[i])
		switch mt {
		case "bold", "strong":
			style = style.Bold(true)
		case "italic", "em":
			style = style.Italic(true)
		case "underline":
			style = style.Underline(true)
		case "strike", "s", "strikethrough":
			style = style.Strikethrough(true)
		case "code":
			// code is leaf-only in render.ex; if it is the innermost mark we
			// switch to the InlineCode chip. Outer marks still apply on top.
			codeChip = true
		case "link":
			if !insideLink {
				hasLink = true
				linkHref = markHref(marks[i])
			}
		}
	}

	var rendered string
	if codeChip {
		// The chip style carries its own bg; layer the accumulated emphasis on
		// top by rendering the chip first, then re-styling is not additive in
		// lipgloss, so we apply InlineCode merged with the emphasis flags.
		rendered = ir.theme.inlineCodeWith(style).Render(value)
	} else {
		rendered = style.Render(value)
	}

	if hasLink {
		return ir.renderLink(linkHref, rendered, ctx)
	}
	return rendered
}

// renderLink wraps already-styled text in the link presentation: underline +
// link color, plus an OSC 8 hyperlink when the profile supports it, else a dim
// " (href)" suffix so the URL is still reachable on a dumb terminal.
func (ir InlineRenderer) renderLink(href, text string, ctx RenderCtx) string {
	href = sanitizeURL(strings.TrimSpace(href))
	styled := ir.theme.Link.Render(text)
	if href == "" {
		return styled
	}
	if ctx.Profile.supportsHyperlinks() {
		// OSC 8: \x1b]8;;<href>\x1b\\<text>\x1b]8;;\x1b\\
		return "\x1b]8;;" + href + "\x1b\\" + styled + "\x1b]8;;\x1b\\"
	}
	return styled + ir.theme.Dim.Render(" ("+href+")")
}

// sanitizeURL strips terminal control bytes (C0 controls + DEL) from a
// document-controlled URL so a href/src can't close or hijack the OSC 8
// hyperlink sequence it gets spliced into (an embedded ST/BEL/CSI byte would
// otherwise emit raw escapes into the reader's terminal). The OSC 8 spec
// forbids control chars in the URI, so well-formed URLs are unaffected; all
// valid printable UTF-8 runes pass through unchanged.
func sanitizeURL(s string) string {
	if strings.IndexFunc(s, isCtrlRune) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		if isCtrlRune(r) {
			return -1
		}
		return r
	}, s)
}

func isCtrlRune(r rune) bool {
	return r < 0x20 || r == 0x7f
}

// markType reads a mark's "type", tolerating a bare string mark.
func markType(m any) string {
	switch v := m.(type) {
	case string:
		return v
	case map[string]any:
		return attrStr(v, "type")
	default:
		return ""
	}
}

// markHref reads a link mark's href from either `attrs.href` (ProseMirror
// shape) or a top-level `href` — exactly the `get_in(mark, ["attrs","href"]) ||
// Map.get(mark, "href")` fallback in apply_mark/3.
func markHref(m any) string {
	mm, ok := m.(map[string]any)
	if !ok {
		return ""
	}
	if attrs, ok := mm["attrs"].(map[string]any); ok {
		if h := attrStr(attrs, "href"); h != "" {
			return h
		}
	}
	return attrStr(mm, "href")
}
