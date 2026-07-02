package pdrender

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	ltable "github.com/charmbracelet/lipgloss/table"
	"github.com/charmbracelet/x/ansi"
)

// ── table ──────────────────────────────────────────────────────────────────
// Mirrors compose_block(table) + the article walk's table/3: a width-aware grid
// via github.com/charmbracelet/lipgloss/table. The HEADER band is OPT-IN — it
// renders ONLY when `head` is present, exactly like the model (no implicit
// rows[0] promotion). `head` is a FLAT array of cell strings; `rows` is an array
// of row arrays. Cells go through the InlineRenderer (bare strings coerce to
// text). .Width(ctx.Width) auto-sizes columns to the available width.
type tableRenderer struct{ ir InlineRenderer }

func (tr tableRenderer) Render(b Block, ctx RenderCtx) []string {
	head := attrSlice(b.Attrs, "head")
	rows := attrSlice(b.Attrs, "rows")

	t := ltable.New().
		Width(clampWidth(ctx.Width)).
		Wrap(true).
		Border(lipgloss.NormalBorder()).
		BorderStyle(ctx.Theme.Rule)

	// Header band: uppercase + muted, only when `head` is non-empty (opt-in).
	hasHead := len(head) > 0
	if hasHead {
		cells := make([]string, 0, len(head))
		for _, c := range head {
			// A head cell is a single cell-string (or inline run); render it,
			// strip styling, uppercase it for the muted band look.
			txt := ansi.Strip(tr.cellString(c, ctx))
			cells = append(cells, strings.ToUpper(txt))
		}
		t.Headers(cells...)
	}

	addedRows := 0
	for _, r := range rows {
		cells := tr.rowCells(r, ctx)
		if len(cells) == 0 {
			continue // skip empty rows — ltable panics on zero-column rows
		}
		t.Row(cells...)
		addedRows++
	}

	// Guard: no columns at all (no head and no non-empty rows) → empty output.
	// lipgloss/table's auto-sizer indexes colWidths[0] on a zero-column table
	// and panics (index out of range), taking down the whole render. Mirrors
	// the guard sheetRenderer already carries.
	if !hasHead && addedRows == 0 {
		return []string{""}
	}

	headerStyle := ctx.Theme.Dim.Bold(true)
	bodyStyle := ctx.Theme.Body
	t.StyleFunc(func(row, col int) lipgloss.Style {
		// table.HeaderRow is -1; style the header band muted+bold, body plain.
		if row == ltable.HeaderRow {
			return headerStyle.Padding(0, 1)
		}
		return bodyStyle.Padding(0, 1)
	})

	return strings.Split(t.Render(), "\n")
}

// rowCells renders a row (an array of cells) to a []string of styled cells.
func (tr tableRenderer) rowCells(row any, ctx RenderCtx) []string {
	cells, ok := row.([]any)
	if !ok {
		// A bare scalar row coerces to a single cell.
		return []string{tr.cellString(row, ctx)}
	}
	out := make([]string, 0, len(cells))
	for _, c := range cells {
		out = append(out, tr.cellString(c, ctx))
	}
	return out
}

// cellString renders one cell. A cell is an array of inline nodes; a bare
// string/number coerces to a text node (mirrors compose_inline_children's scalar
// tolerance + the table cell List.wrap path).
func (tr tableRenderer) cellString(cell any, ctx RenderCtx) string {
	switch v := cell.(type) {
	case []any:
		return tr.ir.Inline(v, ctx)
	case nil:
		return ""
	default:
		return tr.ir.Inline([]any{v}, ctx)
	}
}

// ── figure ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(figure): render the single Child block through the
// registry (full recursion, like section) + a "Figure N." caption below (muted
// italic). N comes from ctx.figureN — the shared document-global counter — which
// we increment here. The child + caption sit inside a light card border.
type figureRenderer struct{ reg *Registry }

func (fr figureRenderer) Render(b Block, ctx RenderCtx) []string {
	n := ctx.nextFigure()

	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome

	var childLines []string
	if b.Child != nil {
		if inner < MinWidth {
			// Narrow: render the child flat (no card) at full width + a caption.
			childLines = fr.reg.Render(*b.Child, ctx.Deeper())
			caption := attrStr(b.Attrs, "caption")
			childLines = append(childLines, fr.caption(n, caption, ctx, clampWidth(ctx.Width)))
			return childLines
		}
		childLines = fr.reg.Render(*b.Child, ctx.Deeper().WithWidth(inner))
	}

	caption := attrStr(b.Attrs, "caption")
	capLine := fr.caption(n, caption, ctx, clampWidth(inner))

	body := lipgloss.JoinVertical(lipgloss.Left, append(childLines, capLine)...)
	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		Width(clampWidth(inner)).
		Render(body)
	return strings.Split(card, "\n")
}

// caption builds the "Figure N. <caption>" line, muted italic, with a bold-ish
// "Figure N." run-in approximated by the caption style. Wrapped to width.
func (fr figureRenderer) caption(n int, caption string, ctx RenderCtx, width int) string {
	lead := "Figure " + itoa(n) + "."
	text := lead
	if caption != "" {
		text = lead + " " + caption
	}
	styled := ctx.Theme.Caption.Render(text)
	lines := wrapLines(styled, width)
	return strings.Join(lines, "\n")
}

// ── action (CTA) ───────────────────────────────────────────────────────────
// Mirrors compose_block(action) + the walk button/2: a button-styled run. A
// `priority: "primary"` tone fills the accent background with a contrasting
// foreground (the publishBtnStyle idiom); secondary draws an accent-outline box.
// The `label` carries an OSC 8 hyperlink to `href` when the profile supports it,
// else a dim " (href)" suffix.
type actionRenderer struct{}

func (actionRenderer) Render(b Block, ctx RenderCtx) []string {
	label := attrStr(b.Attrs, "label")
	href := sanitizeURL(strings.TrimSpace(attrStr(b.Attrs, "href")))
	priority := attrStr(b.Attrs, "priority")

	var style lipgloss.Style
	if priority == "primary" {
		style = ctx.Theme.ActionPrimary
	} else {
		style = ctx.Theme.ActionSecondary
	}

	rendered := style.Render(" " + label + " ")

	if href != "" {
		if ctx.Profile.supportsHyperlinks() {
			rendered = "\x1b]8;;" + href + "\x1b\\" + rendered + "\x1b]8;;\x1b\\"
		} else {
			rendered = rendered + ctx.Theme.Dim.Render(" ("+href+")")
		}
	}
	return strings.Split(rendered, "\n")
}

// ── pullquote ──────────────────────────────────────────────────────────────
// Mirrors compose_block(pullquote): italic + muted + a left terracotta bar (▌),
// indented. Body is inline `content` wrapped to width-2 (bar + space).
type pullquoteRenderer struct{ ir InlineRenderer }

func (pr pullquoteRenderer) Render(b Block, ctx RenderCtx) []string {
	inline := pr.ir.Inline(attrSlice(b.Attrs, "content"), ctx)
	styled := ctx.Theme.Pullquote.Render(inline)

	const chrome = 2 // "▌ "
	inner := ctx.Width - chrome
	if inner < MinWidth {
		return wrapLines(styled, ctx.Width)
	}

	bar := ctx.Theme.PullquoteBar.Render("▌")
	wrapped := wrapLines(styled, inner)
	out := make([]string, 0, len(wrapped))
	for _, line := range wrapped {
		out = append(out, bar+" "+line)
	}
	return out
}

// ── ingress ────────────────────────────────────────────────────────────────
// Mirrors compose_block(ingress): the lead/standfirst paragraph. Full-width,
// NOT dimmed — read as a standfirst via a left accent bar + brighter ink (the
// terminal has no font size, so weight/brightness/bar stand in for "1.28rem").
type ingressRenderer struct{ ir InlineRenderer }

func (inr ingressRenderer) Render(b Block, ctx RenderCtx) []string {
	inline := inr.ir.Inline(attrSlice(b.Attrs, "content"), ctx)
	styled := ctx.Theme.Ingress.Render(inline)

	const chrome = 2 // "▌ "
	inner := ctx.Width - chrome
	if inner < MinWidth {
		return wrapLines(styled, ctx.Width)
	}

	bar := ctx.Theme.IngressBar.Render("▌")
	wrapped := wrapLines(styled, inner)
	out := make([]string, 0, len(wrapped))
	for _, line := range wrapped {
		out = append(out, bar+" "+line)
	}
	return out
}

// ── eyebrow ────────────────────────────────────────────────────────────────
// Mirrors compose_block(eyebrow): UPPERCASE, letter-spaced, accent kicker. The
// terminal can't kern, so letter-spacing is faked by joining the chars with a
// space — an honest approximation of 0.08em tracking.
type eyebrowRenderer struct{}

func (eyebrowRenderer) Render(b Block, ctx RenderCtx) []string {
	text := strings.ToUpper(attrStr(b.Attrs, "text"))
	spaced := letterSpace(text)
	styled := ctx.Theme.Eyebrow.Render(spaced)
	return wrapLines(styled, ctx.Width)
}

// letterSpace inserts a single space between each rune (the terminal stand-in
// for CSS letter-spacing). Existing spaces become a wider gap, which reads fine.
func letterSpace(s string) string {
	if s == "" {
		return ""
	}
	runes := []rune(s)
	var b strings.Builder
	for i, r := range runes {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// ── byline ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(byline): `items` joined " · " (else `text`), muted, with
// a thin bottom rule beneath.
type bylineRenderer struct{}

func (bylineRenderer) Render(b Block, ctx RenderCtx) []string {
	text := bylineText(b.Attrs)
	styled := ctx.Theme.Byline.Render(text)
	lines := wrapLines(styled, ctx.Width)

	// A thin bottom rule spanning the visible byline width (capped at ctx.Width).
	ruleW := lipgloss.Width(text)
	if ruleW > ctx.Width {
		ruleW = ctx.Width
	}
	if ruleW < 1 {
		ruleW = 1
	}
	rule := ctx.Theme.Rule.Render(strings.Repeat("─", ruleW))
	return append(lines, rule)
}

// bylineText resolves the byline string: `items` (joined " · ") wins; else the
// plain `text` field — mirroring compose_block(byline)'s case.
func bylineText(m map[string]any) string {
	if items := attrSlice(m, "items"); len(items) > 0 {
		parts := make([]string, 0, len(items))
		for _, it := range items {
			parts = append(parts, toStr(it))
		}
		return strings.Join(parts, " · ")
	}
	return attrStr(m, "text")
}
