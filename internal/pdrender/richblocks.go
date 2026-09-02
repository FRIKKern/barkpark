package pdrender

import (
	"math"
	"regexp"
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
//
// NOT on the shared Flex solver (BY DESIGN): a table is not a divide-formula
// surface — it delegates to lipgloss/table's OWN measured column auto-sizer
// (per-column min/max content widths + wrap), which the equal-cell Flex.Measure
// divide can't reproduce. Force-porting it onto Flex would change the bytes AND
// lose the content-aware wrap, so table stays on its native sizer. (Settled call —
// left self-documented so a future "why isn't table on the solver?" audit doesn't
// re-open it, same spirit as the section breakpoints no-mode note.)
//
// TYPED COLUMNS (opt-in, CONTENT ONLY): an optional `cols` attr — an
// index-aligned array of {type} maps — tags each column text | num | delta |
// spark. It changes only the CELL BODY (and, for num/delta, the per-column
// alignment via the existing StyleFunc); it never touches width math, so the
// lipgloss/table auto-sizer stays the sole width authority. `cols` ABSENT ⇒ every
// column is text ⇒ the render is byte-identical to a table with no spec. The key
// is `cols`, NOT `columns` (an overloaded layout block name + layout attr).
type tableRenderer struct{ ir InlineRenderer }

func (tr tableRenderer) Render(b Block, ctx RenderCtx) []string {
	head := attrSlice(b.Attrs, "head")
	rows := attrSlice(b.Attrs, "rows")
	columnHead, columnKeys := tableColumns(attrSlice(b.Attrs, "columns"))
	if len(head) == 0 && len(columnHead) > 0 {
		head = columnHead
		if len(columnKeys) > 0 {
			normalizedRows := make([]any, 0, len(rows))
			for _, row := range rows {
				normalizedRows = append(normalizedRows, recordRow(row, columnKeys))
			}
			rows = normalizedRows
		}
	}
	if len(head) == 0 && len(rows) > 0 {
		if row, ok := rows[0].(map[string]any); ok {
			if header, _ := row["header"].(bool); header {
				if cells, ok := row["cells"].([]any); ok {
					head = cells
					rows = rows[1:]
				}
			} else if cells, ok := row["cells"].([]any); ok && allHeaderCells(cells) {
				head = cells
				rows = rows[1:]
			}
		}
	}
	colTypes := parseColTypes(attrSlice(b.Attrs, "cols"))

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
		cells := tr.rowCells(r, colTypes, ctx)
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
		// num/delta columns right-align so digits/deltas line up on their ones
		// place — the header rides right too so the label sits over its column.
		// colRightAlign is false for every column when `cols` is absent, so this
		// path stays byte-identical to the legacy render.
		if row == ltable.HeaderRow {
			hs := headerStyle.Padding(0, 1)
			if colRightAlign(colTypes, col) {
				hs = hs.Align(lipgloss.Right)
			}
			return hs
		}
		bs := bodyStyle.Padding(0, 1)
		if colRightAlign(colTypes, col) {
			bs = bs.Align(lipgloss.Right)
		}
		return bs
	})

	return strings.Split(t.Render(), "\n")
}

// rowCells renders a row (an array of cells) to a []string of styled cells,
// each cell rendered per its column type (index-aligned to colTypes; text/legacy
// when colTypes is nil or the index is out of range).
func (tr tableRenderer) rowCells(row any, colTypes []string, ctx RenderCtx) []string {
	if wrapped, ok := row.(map[string]any); ok {
		if cells, ok := wrapped["cells"].([]any); ok {
			row = cells
		}
	}
	cells, ok := row.([]any)
	if !ok {
		// A bare scalar row coerces to a single cell (column 0).
		return []string{tr.typedCell(row, colType(colTypes, 0), ctx)}
	}
	out := make([]string, 0, len(cells))
	for i, c := range cells {
		out = append(out, tr.typedCell(c, colType(colTypes, i), ctx))
	}
	return out
}

// typedCell renders one cell according to its column type. num shares the text
// BODY (only its alignment differs, in the StyleFunc), so a num column stays
// content-identical to legacy text; delta and spark transform the body.
func (tr tableRenderer) typedCell(cell any, typ string, ctx RenderCtx) string {
	switch typ {
	case "delta":
		return tr.deltaCell(cell, ctx)
	case "spark":
		return tr.sparkCell(cell, ctx)
	default: // text, num, "" — legacy inline body
		return tr.cellString(cell, ctx)
	}
}

// deltaCell prefixes a numeric cell with a leading direction glyph derived from
// its SIGN (▲ up / ▼ down / - flat), then the magnitude — glyph-first, so the
// direction survives with zero color (color would be reinforcement only). A cell
// that does not coerce to a number falls back to the legacy text body (no glyph).
func (tr tableRenderer) deltaCell(cell any, ctx RenderCtx) string {
	f, ok := toFloat(cell)
	if !ok {
		return tr.cellString(cell, ctx)
	}
	glyph := "-"
	switch {
	case f > 0:
		glyph = "▲"
	case f < 0:
		glyph = "▼"
	}
	return glyph + " " + toStr(math.Abs(f))
}

// sparkCell renders a numeric series cell as the canonical stat.go sparkline
// capped to 14 cells (the ONE sparkline primitive — no new ladder, no braille
// canvas). A non-series / empty cell falls back to the legacy text body.
func (tr tableRenderer) sparkCell(cell any, ctx RenderCtx) string {
	series, ok := cell.([]any)
	if !ok {
		return tr.cellString(cell, ctx)
	}
	vals := make([]float64, 0, len(series))
	for _, v := range series {
		if f, ok := toFloat(v); ok {
			vals = append(vals, f)
		}
	}
	if len(vals) == 0 {
		return tr.cellString(cell, ctx)
	}
	return sparkline(vals, 14)
}

// parseColTypes reads the optional `cols` spec into an index-aligned slice of
// column type names. Each entry is a {type} map; a missing or unknown type falls
// back to "text" (the legacy path). An ABSENT `cols` yields nil — and nil means
// every column is text, i.e. byte-identical to a table carrying no spec.
func parseColTypes(cols []any) []string {
	if len(cols) == 0 {
		return nil
	}
	out := make([]string, len(cols))
	for i, c := range cols {
		typ := "text"
		if m, ok := c.(map[string]any); ok {
			switch t := attrStr(m, "type"); t {
			case "num", "delta", "spark", "text":
				typ = t
			}
		}
		out[i] = typ
	}
	return out
}

// colType returns the type of column i (text when out of range or unspecified).
func colType(types []string, i int) string {
	if i >= 0 && i < len(types) {
		return types[i]
	}
	return "text"
}

// colRightAlign reports whether column col right-aligns (num + delta). Always
// false when `cols` is absent, which is what keeps the legacy render byte-stable.
func colRightAlign(types []string, col int) bool {
	switch colType(types, col) {
	case "num", "delta":
		return true
	}
	return false
}

// cellString renders one cell. A cell is an array of inline nodes; a bare
// string/number coerces to a text node (mirrors compose_inline_children's scalar
// tolerance + the table cell List.wrap path).
func (tr tableRenderer) cellString(cell any, ctx RenderCtx) string {
	switch v := cell.(type) {
	case []any:
		return tr.ir.Inline(flattenCellNodes(v), ctx)
	case map[string]any:
		if content, ok := v["content"].([]any); ok {
			return tr.ir.Inline(flattenCellNodes(content), ctx)
		}
		if text, ok := v["text"].(string); ok {
			return tr.ir.Inline([]any{text}, ctx)
		}
		return tr.ir.Inline([]any{v}, ctx)
	case nil:
		return ""
	default:
		return tr.ir.Inline([]any{v}, ctx)
	}
}

func flattenCellNodes(nodes []any) []any {
	out := make([]any, 0, len(nodes))
	for _, node := range nodes {
		if block, ok := node.(map[string]any); ok && attrStr(block, "type") == "paragraph" {
			if content, ok := block["content"].([]any); ok {
				out = append(out, content...)
				continue
			}
		}
		out = append(out, node)
	}
	return out
}

func tableColumns(columns []any) ([]any, []string) {
	if len(columns) == 0 {
		return nil, nil
	}
	head := make([]any, 0, len(columns))
	keys := make([]string, 0, len(columns))
	for _, raw := range columns {
		column, ok := raw.(map[string]any)
		if !ok {
			return nil, nil
		}
		key := attrStr(column, "key")
		if key == "" {
			text := attrStr(column, "text")
			if text == "" {
				return nil, nil
			}
			head = append(head, text)
			continue
		}
		label := attrStr(column, "label")
		if label == "" {
			label = key
		}
		keys = append(keys, key)
		head = append(head, label)
	}
	if len(keys) == 0 && len(head) == len(columns) {
		return head, nil
	}
	if len(keys) != len(columns) {
		return nil, nil
	}
	return head, keys
}

func recordRow(raw any, keys []string) any {
	row, ok := raw.(map[string]any)
	if !ok {
		return raw
	}
	cells := make([]any, 0, len(keys))
	for _, key := range keys {
		cells = append(cells, row[key])
	}
	return cells
}

func allHeaderCells(cells []any) bool {
	if len(cells) == 0 {
		return false
	}
	for _, raw := range cells {
		cell, ok := raw.(map[string]any)
		header, _ := cell["header"].(bool)
		if !ok || !header {
			return false
		}
	}
	return true
}

// ── figure ─────────────────────────────────────────────────────────────────
// Mirrors compose_block(figure): render the single Child block through the
// registry (full recursion, like section) + the AUTHOR'S caption below (muted
// italic), with an author-typed "Figure N." lead emphasised exactly as the web
// reader does. pdrender invents no number of its own — see figureCaption.
// The child + caption sit inside a light card border.
type figureRenderer struct{ reg *Registry }

func (fr figureRenderer) Render(b Block, ctx RenderCtx) []string {
	const chrome = 4 // rounded border (2) + padding (2)
	inner := ctx.Width - chrome

	caption := attrStr(b.Attrs, "caption")

	// The child is rendered FIRST, at the width it would really get, because the
	// blank test is asked of its composed bytes and not of the `child` key (see
	// blankFigure). Both legs below reuse these exact lines, so the guard costs
	// no second render.
	narrow := inner < MinWidth
	var childLines []string
	if b.Child != nil {
		if narrow {
			childLines = fr.reg.Render(*b.Child, ctx.Deeper())
		} else {
			childLines = fr.reg.Render(*b.Child, ctx.Deeper().WithWidth(inner))
		}
	}

	// EMPTY-CHROME INVARIANT (blank.go): a figure whose child contributes no
	// bytes AND whose caption is blank renders nothing — not an empty rounded
	// card, the terminal twin of the 183-byte empty <figure> the web reader
	// stopped emitting in #14991. A caption with no child still renders (an
	// author's prose is never deleted to tidy a border), and a real child with
	// no caption is unchanged.
	if blankFigure(b.Attrs, childLines) {
		return nil
	}

	if b.Child != nil && narrow {
		// Narrow: render the child flat (no card) at full width + a caption.
		if line := fr.caption(caption, ctx, clampWidth(ctx.Width)); line != "" {
			childLines = append(childLines, line)
		}
		return childLines
	}

	cardLines := childLines
	if capLine := fr.caption(caption, ctx, clampWidth(inner)); capLine != "" {
		cardLines = append(cardLines, capLine)
	}

	body := lipgloss.JoinVertical(lipgloss.Left, cardLines...)
	card := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(ruleColor(ctx.Theme)).
		Padding(0, 1).
		// lipgloss Width INCLUDES the padding (border excluded): inner+2 gives the
		// children their full `inner` columns and lands the border on ctx.Width.
		// Width(inner) left inner-2 for content, force-wrapping bordered children.
		Width(clampWidth(inner + 2)).
		Render(body)
	return strings.Split(card, "\n")
}

// caption builds the caption line beneath a figure: the author's text, muted
// italic, wrapped to width. Empty caption → empty line (nothing to say).
func (fr figureRenderer) caption(caption string, ctx RenderCtx, width int) string {
	styled := figureCaption(sanitizeText(caption), ctx)
	if styled == "" {
		return ""
	}
	return strings.Join(wrapLines(styled, width), "\n")
}

// figureCaptionLead matches an AUTHOR-TYPED "Figure N." run-in — the same shape
// the web reader detects (figures.ex figcaption_inner/1).
var figureCaptionLead = regexp.MustCompile(`(?s)^(Figure\s+\S+?\.)\s*(.*)$`)

// figureCaption styles a figure/diagram caption the way the web reader does:
// DETECT an author-typed "Figure N." lead and emphasise it (bold over the
// muted-italic caption tone — the terminal analogue of figures.ex's <b> run-in),
// and GENERATE NOTHING. pdrender used to prepend its own document-global
// "Figure N.", so a paper whose author had typed a number printed two
// contradictory numbers on one caption line; the terminal must never contradict
// the author. If auto-numbering is ever wanted it lands on all three surfaces in
// one wave (charter D11), not here. Empty caption → "" (no line at all).
func figureCaption(caption string, ctx RenderCtx) string {
	if caption == "" {
		return ""
	}
	if m := figureCaptionLead.FindStringSubmatch(caption); m != nil {
		lead := ctx.Theme.Caption.Bold(true).Render(m[1])
		if m[2] == "" {
			return lead
		}
		return lead + ctx.Theme.Caption.Render(" "+m[2])
	}
	return ctx.Theme.Caption.Render(caption)
}

// ── action (CTA) ───────────────────────────────────────────────────────────
// Mirrors compose_block(action) + the walk button/2: a button-styled run. A
// `priority: "primary"` tone fills the accent background with a contrasting
// foreground (the publishBtnStyle idiom); secondary draws an accent-outline box.
// The `label` carries an OSC 8 hyperlink to `href` when the profile supports it,
// else a dim " (href)" suffix.
type actionRenderer struct{}

func (actionRenderer) Render(b Block, ctx RenderCtx) []string {
	// EMPTY-CHROME INVARIANT (blank.go): an action with NEITHER a label NOR an
	// href renders nothing — not a two-space button chip that says nothing and
	// goes nowhere. It is exactly what the Studio canvas seeds
	// (`Blocks.default_block("action", id)` is `%{"href" => "", "label" => ""}`),
	// which the web reader stopped painting in #14991. `priority` is a button
	// skin, so a priority-only block is still blank.
	if blankAction(b.Attrs) {
		return nil
	}

	label := sanitizeDisplayText(attrStr(b.Attrs, "label"))
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

// ── embed ───────────────────────────────────────────────────────────────────
// Mirrors the Elixir walker's PdEmbed (compose_block("embed") → walk PdEmbed).
// The terminal has no resolved-embed palette (transclusion is a web/email
// concern), so it renders the UNRESOLVED placeholder the Elixir walker shows for
// the same case — a muted "↪ <target>" line. Before this renderer existed, an
// embed block fell through to the "unknown block" fallback in the TUI while the
// web reader rendered it fine — a cross-surface divergence. A URL target becomes
// an OSC-8 hyperlink where the terminal supports it (mirrors actionRenderer).
type embedRenderer struct{}

func (embedRenderer) Render(b Block, ctx RenderCtx) []string {
	target := sanitizeText(strings.TrimSpace(attrStr(b.Attrs, "target")))
	if target == "" {
		return []string{ctx.Theme.Dim.Render("↪ (embed)")}
	}
	line := ctx.Theme.Dim.Render("↪ " + target)
	if url := sanitizeURL(target); url != "" && ctx.Profile.supportsHyperlinks() {
		line = "\x1b]8;;" + url + "\x1b\\" + line + "\x1b]8;;\x1b\\"
	}
	return []string{line}
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
	text := strings.ToUpper(sanitizeText(attrStr(b.Attrs, "text")))
	spaced := letterSpace(text)
	if lipgloss.Width(spaced) > ctx.Width {
		spaced = text
	}
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
	text := sanitizeText(bylineText(b.Attrs))
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
