package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// ── List / DocList pane ──────────────────────────────────────────────────────

// maxInt returns the larger of two ints (avoids negative repeat counts).
func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// renderListInterior is the single, line-accurate windowing primitive for every
// list pane — both the focused renderPane and the right-pane previews route
// through it so they can never diverge. It returns the exact interior lines for
// the items (NOT the header/divider/border), windowed so pane.Cursor's full
// rendered line span is always inside the window, with the partially-visible
// trailing row hard-truncated so it NEVER emits more than interiorHeight lines.
//
// interiorHeight is the rows available for items PLUS the affordance row. When
// the content is clipped (top or bottom hidden), one interior row is reserved
// for the dim "↑ N more" / "↓ N more" counter; when the list fits, no row is
// reserved and the output is byte-identical to the pre-change flush render.
//
// isActive drives the selected (active pane) vs dim-cursor (inactive/preview)
// styling of the cursor row. above/below count items hidden above / below the
// window (0/0 == the list fits and no affordance row is emitted).
func (m model) renderListInterior(pane Pane, width, interiorHeight int, isActive bool) (lines []string, above, below int) {
	if interiorHeight < 1 {
		interiorHeight = 1
	}

	// Render every item to its physical lines once, recording each item's start
	// line + span. Doc-list items are 2 lines (title + subtitle); structure
	// items and dividers are 1 line — line-accurate, no item-vs-line miscount.
	rsStart := make([]int, len(pane.Items))
	rsLen := make([]int, len(pane.Items))
	var allLines []string
	for i, item := range pane.Items {
		rsStart[i] = len(allLines)
		var il []string
		if item.IsDivider {
			il = []string{dimStyle.Render("  " + strings.Repeat("─", maxInt(width-4, 0)))}
		} else {
			isSelected := i == pane.Cursor && isActive
			isCursor := i == pane.Cursor && !isActive
			il = m.renderPaneItem(item, width, isSelected, isCursor, pane.IsDocList)
		}
		// Line-accuracy backstop: a styled item whose content exceeds `width`
		// soft-wraps into a single string carrying embedded newlines — len(il)
		// would then undercount physical rows and the window would overflow the
		// box (and the column would exceed its width). Split any embedded newlines
		// and hard-truncate each physical segment to `width` so rsLen matches the
		// real rendered height and nothing can spill horizontally. Items that fit
		// (the common case — real icons are short) pass through byte-identical.
		il = clampItemLines(il, width)
		rsLen[i] = len(il)
		allLines = append(allLines, il...)
	}
	total := len(allLines)

	// Short list: fits flush, no affordance — byte-identical to today.
	if total <= interiorHeight {
		return allLines, 0, 0
	}

	// Clipped: reserve one row for the affordance, so items get interiorHeight-1.
	itemRows := interiorHeight - 1
	if itemRows < 1 {
		itemRows = 1
	}

	// Cursor-follow window: keep pane.Cursor's full line span inside the window.
	cursor := pane.Cursor
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= len(pane.Items) {
		cursor = len(pane.Items) - 1
	}
	cStart := rsStart[cursor]
	cEnd := cStart + rsLen[cursor] // exclusive

	// Start from the persisted offset, then nudge to satisfy cursor-follow.
	scroll := pane.Scroll
	if scroll < 0 {
		scroll = 0
	}
	if cStart < scroll {
		scroll = cStart // cursor above window → align top to cursor
	}
	if cEnd > scroll+itemRows {
		scroll = cEnd - itemRows // cursor below window → align bottom to cursor
	}
	// Clamp so we never scroll past the end or below zero.
	maxScroll := total - itemRows
	if maxScroll < 0 {
		maxScroll = 0
	}
	if scroll > maxScroll {
		scroll = maxScroll
	}
	if scroll < 0 {
		scroll = 0
	}

	// Emit exactly itemRows lines from the window, hard-truncating any partial
	// trailing row beyond the budget.
	end := scroll + itemRows
	if end > total {
		end = total
	}
	out := append([]string(nil), allLines[scroll:end]...)

	// Count items fully hidden above / below the window.
	for i := range pane.Items {
		if rsStart[i]+rsLen[i] <= scroll {
			above++
		} else if rsStart[i] >= end {
			below++
		}
	}

	// Affordance row (dim chrome). The bottom counter wins the single reserved
	// row when both edges are clipped — it signals there is more to scroll into.
	var aff string
	if below > 0 {
		aff = dimStyle.Render(fmt.Sprintf(" ↓ %d more", below))
	} else if above > 0 {
		aff = dimStyle.Render(fmt.Sprintf(" ↑ %d more", above))
	}
	out = append(out, aff)
	if len(out) > interiorHeight {
		out = out[:interiorHeight]
	}
	return out, above, below
}

// listScrollOffset recomputes the persisted Pane.Scroll for the given interior
// height so cursor-follow windowing survives across renders and resizes. Mirrors
// the windowing math in renderListInterior; called on cursor moves and resize.
func (m model) listScrollOffset(pane Pane, width, interiorHeight int) int {
	if interiorHeight < 1 {
		interiorHeight = 1
	}
	// Total rendered lines (2 per doc-list item, 1 otherwise).
	total := 0
	starts := make([]int, len(pane.Items))
	lens := make([]int, len(pane.Items))
	for i, item := range pane.Items {
		starts[i] = total
		n := 1
		if !item.IsDivider && pane.IsDocList {
			n = 2
		}
		lens[i] = n
		total += n
	}
	if total <= interiorHeight {
		return 0
	}
	itemRows := interiorHeight - 1
	if itemRows < 1 {
		itemRows = 1
	}
	cursor := pane.Cursor
	if cursor < 0 {
		cursor = 0
	}
	if cursor >= len(pane.Items) {
		cursor = len(pane.Items) - 1
	}
	cStart := starts[cursor]
	cEnd := cStart + lens[cursor]
	scroll := pane.Scroll
	if scroll < 0 {
		scroll = 0
	}
	if cStart < scroll {
		scroll = cStart
	}
	if cEnd > scroll+itemRows {
		scroll = cEnd - itemRows
	}
	maxScroll := total - itemRows
	if maxScroll < 0 {
		maxScroll = 0
	}
	if scroll > maxScroll {
		scroll = maxScroll
	}
	if scroll < 0 {
		scroll = 0
	}
	return scroll
}

// listInteriorHeight returns the item+affordance budget for a list pane whose
// content area is boxHeight lines (the lines slice is truncated to boxHeight
// before the border wraps it). Header(1) + divider(1) are subtracted; the
// border's +2 rows live outside the lines slice, so they are NOT subtracted
// here. Floored at 1.
func (m model) listInteriorHeight(boxHeight int) int {
	ih := boxHeight - 2 // header + divider
	if ih < 1 {
		ih = 1
	}
	return ih
}

func (m model) renderPane(pane Pane, width, height int, isActive bool) string {
	var lines []string

	// Header — headerStyle has Padding(0,1) which is inside Width()
	icon := ""
	if pane.Node.Icon != "" {
		icon = pane.Node.Icon + " "
	}
	headerText := icon + pane.Node.Title
	if pane.IsDocList {
		headerText += dimStyle.Render(" " + docListCount(pane))
	}
	lines = append(lines, headerStyle.Width(width).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width)))

	// Interior: header + divider already consumed 2 of the box's content rows;
	// the box is height tall (border counts toward .Height), so the item area is
	// height - 4 (border 2 + header + divider). renderListInterior windows it,
	// clips to budget, and reserves an affordance row only when actually clipped.
	interiorHeight := m.listInteriorHeight(height)
	var interior []string
	if pane.IsDocList && len(pane.Items) == 0 && pane.ReadFailed {
		// The read never landed (transport error / 401 / 5xx). Say so — the
		// empty-state placebo below would tell the user this type holds
		// nothing, which is a claim we have no evidence for.
		interior = failedDocListInterior()
	} else if pane.IsDocList && len(pane.Items) == 0 {
		// A focused doc-list pane with nothing in it would otherwise render an
		// empty box — advertise the create affordance instead of blank space.
		interior = emptyDocListInterior(true)
	} else {
		interior, _, _ = m.renderListInterior(pane, width, interiorHeight, isActive)
	}
	lines = append(lines, interior...)

	// Pad
	for len(lines) < height {
		lines = append(lines, strings.Repeat(" ", width))
	}
	if len(lines) > height {
		lines = lines[:height]
	}

	content := lipgloss.JoinVertical(lipgloss.Left, lines...)
	if isActive {
		return activePaneBorder.Width(width).Height(height).Render(content)
	}
	return paneBorder.Width(width).Height(height).Render(content)
}

func (m model) renderPaneItem(item PaneItem, width int, selected, isCursor, isDocList bool) []string {
	style := normalItemStyle
	if selected {
		style = selectedItemStyle
	}

	if isDocList {
		// list_preview extras (schema-declared; Studio parity). The meta value
		// joins the subtitle row (dim, " · "-separated); the badge right-aligns
		// on the title row, bracketed dim like the editor header's "[status]"
		// badge. Degradation order mirrors the toolbar tiers: the badge is the
		// FIRST thing dropped when the pane narrows — the title keeps at least
		// minTitleWithBadge columns or the badge goes. With no declaration
		// (item.Badge == "" and item.Meta == "") every string below is
		// byte-identical to the pre-list_preview rendering.
		sub := item.Subtitle
		if item.Meta != "" {
			if sub == "" {
				sub = item.Meta
			} else {
				sub += " · " + item.Meta
			}
		}
		titleMax := width - 6
		badge := ""
		if item.Badge != "" {
			b := "[" + item.Badge + "]"
			if titleMax-(lipgloss.Width(b)+1) >= minTitleWithBadge {
				badge = b
				titleMax -= lipgloss.Width(b) + 1
			}
		}

		dot := statusStyle(item.Status).Render(item.Icon)
		title := truncate(item.Title, titleMax)
		pad := ""
		if badge != "" {
			// Right-align the badge: leading " %s %s" is 2 cols + icon + title.
			gap := width - 2 - lipgloss.Width(item.Icon) - lipgloss.Width(title) -
				lipgloss.Width(badge) - 1
			if gap < 1 {
				gap = 1
			}
			pad = strings.Repeat(" ", gap)
		}

		// Bulk mark (space — bulk.go): marked rows swap the leading space for
		// a highlighted ✓, same physical width so nothing shifts.
		lead := " "
		if item.Doc != nil && m.marked != nil {
			if _, ok := m.marked[strings.TrimPrefix(item.Doc.ID, "drafts.")]; ok {
				lead = lipgloss.NewStyle().Bold(true).Foreground(highlight).Render("✓")
			}
		}

		line1 := fmt.Sprintf("%s%s %s", lead, dot, style.Render(title))
		if badge != "" {
			line1 += pad + dimStyle.Render(badge)
		}
		line2 := fmt.Sprintf("     %s", dimStyle.Render(sub))
		if selected {
			line1 = selectedItemStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title) + pad + badge)
			line2 = selectedItemStyle.Width(width).Render(fmt.Sprintf("     %s", sub))
		} else if isCursor {
			line1 = inactiveCursorStyle.Width(width).Render(fmt.Sprintf(" %s %s", dot, title) + pad + badge)
			line2 = inactiveCursorStyle.Width(width).Render(fmt.Sprintf("     %s", sub))
		}
		return []string{line1, line2}
	}

	// Structure list item
	icon := item.Icon
	if icon == "" {
		icon = " "
	}
	title := truncate(item.Title, width-8)
	chevron := dimStyle.Render("›")
	inner := fmt.Sprintf(" %s %s", icon, title)
	gap := width - lipgloss.Width(inner) - 2
	if gap < 0 {
		gap = 0
	}
	line := style.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)
	if isCursor && !selected {
		line = inactiveCursorStyle.Width(width).Render(inner + strings.Repeat(" ", gap) + chevron)
	}
	return []string{line}
}

// ── Editor pane ──────────────────────────────────────────────────────────────

func (m model) renderEditor(width, height int, isActive bool) string {
	if m.selectedDoc == nil && m.docReadFailed {
		// The read did not land. The empty-state splash below would invite the
		// user to "select a document" from a list we never managed to fetch.
		return m.renderReadFailedState(width, height)
	}
	if m.selectedDoc == nil || m.editorSchema == nil {
		return m.renderEmptyState(width, height)
	}

	// Use viewport for scrolling
	var content string
	if m.vpReady {
		content = m.viewport.View()
	} else {
		// Fallback before first WindowSizeMsg
		content = m.buildEditorContent(width)
	}

	if isActive {
		return activePaneBorder.Width(width).Height(height).Render(content)
	}
	return paneBorder.Width(width).Height(height).Render(content)
}

// buildEditorContent renders the full editor content as a string.
// The viewport handles scrolling and clipping.
// fieldGroupHeader returns the dim section-header line rendered BEFORE field
// i when it starts a new schema group ("" otherwise). Shared by
// buildEditorContent (render) and scrollToField (line accounting) so the two
// can never drift — every header is exactly TWO physical lines (header +
// blank).
func (m model) fieldGroupHeader(i int) string {
	fields := m.editorSchema.Fields
	if i >= len(fields) || fields[i].Group == "" {
		return ""
	}
	if i > 0 && fields[i-1].Group == fields[i].Group {
		return ""
	}
	return dimStyle.Render("  ── " + strings.ToUpper(fields[i].Group) + " ──")
}

func (m model) buildEditorContent(width int) string {
	if m.selectedDoc == nil || m.editorSchema == nil {
		return ""
	}

	// Paper branch: a paper with a decoded block tree renders as a real document
	// via pdrender, NOT as a field form. buildDocPreview routes through here too,
	// so papers render in the preview pane for free. Any non-paper (or a paper
	// with no/undecodable blocks) falls through to the field-form loop unchanged.
	if m.isCurrentPaper() {
		return m.buildPaperContent(width)
	}

	var lines []string

	// Header
	dot := statusStyle(m.selectedDoc.Status).Render(statusIcon(m.selectedDoc.Status))
	title := truncate(m.selectedDoc.Title, width-20)
	header := fmt.Sprintf(" %s %s", dot, headerStyle.Render(title))
	if m.selectedDoc.Status != "" {
		header += " " + dimStyle.Render("["+m.selectedDoc.Status+"]")
	}
	lines = append(lines, header)
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", maxInt(width-2, 0))))

	// Schema info
	lines = append(lines, dimStyle.Render(fmt.Sprintf(
		" %s %s  |  %d fields", m.editorSchema.Icon, m.editorSchema.Title, len(m.editorSchema.Fields),
	)))
	lines = append(lines, "")

	// Fields
	fieldWidth := width - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	isEditorFocused := m.focus.Target == FocusEditor
	for i, field := range m.editorSchema.Fields {
		if h := m.fieldGroupHeader(i); h != "" {
			lines = append(lines, h, "")
		}
		isFocused := isEditorFocused && i == m.fieldCursor
		isEditing := isFocused && m.editing
		lines = append(lines, m.renderField(field, fieldWidth, isFocused, isEditing)...)
		if i < len(m.editorSchema.Fields)-1 {
			lines = append(lines, "")
		}
	}

	// Footer
	lines = append(lines, "")
	lines = append(lines, dividerStyle.Render(" "+strings.Repeat("─", maxInt(width-4, 0))))

	footerLeft := dimStyle.Render(fmt.Sprintf("  Edited %s", timeAgo(m.selectedDoc.UpdatedAt)))

	// Publish affordance reflects the doc's real state (the old static
	// "Publish" button was wired to nothing): a draft advertises the ctrl+p
	// binding; a published doc shows a dim, action-free checkmark; any other
	// status (e.g. a select-field "active") shows neither.
	var publishBtn string
	switch m.selectedDoc.Status {
	case "draft":
		publishBtn = publishBtnStyle.Render("Ctrl+P publish")
	case "published":
		publishBtn = dimStyle.Render("published ✓ · U unpublish")
	}

	var footerRight string
	if m.dirty {
		footerRight = lipgloss.NewStyle().
			Foreground(amberDot).Bold(true). // warn role via semrole (amberDot=roleColor("warn"))
			Render("* Unsaved") + "  " +
			dimStyle.Render("Ctrl+S save")
		if publishBtn != "" {
			footerRight += "  " + publishBtn
		}
	} else {
		footerRight = publishBtn
	}
	gap := width - lipgloss.Width(footerLeft) - lipgloss.Width(footerRight) - 4
	if gap < 0 {
		gap = 0
	}
	lines = append(lines, footerLeft+strings.Repeat(" ", gap)+footerRight)

	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// indentLines prefixes n spaces to EVERY line of s. lipgloss box styles
// (RoundedBorder etc.) render to a multi-line string (top border / content
// row(s) / bottom border); a bare `"  " + box` concat only indents the first
// line, shifting the top border right while content + bottom border stay at
// column 0. Indenting every line keeps the whole box a clean rectangle.
func indentLines(s string, n int) string {
	pad := strings.Repeat(" ", n)
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = pad + p
	}
	return strings.Join(parts, "\n")
}

// renderField generates the TUI lines for a single schema field.
func (m model) renderField(field Field, width int, isFocused, isEditing bool) []string {
	var lines []string

	// Label — highlight when focused. A right-aligned dim annotation (e.g. the
	// slug field's [gen]) rides on the label line so every field box can keep the
	// same full width and all the box right edges line up.
	labelText := "  " + strings.ToUpper(field.Title)
	if m.dirtyValues != nil {
		if _, dirty := m.dirtyValues[field.Name]; dirty {
			// Unsaved-change marker (Sanity's per-field edited dot): commits
			// land in dirtyValues and clear on ctrl+s — the dot tracks that.
			labelText += " ●"
		}
	}
	if field.Required {
		// Sanity's required marker; the annotation adds "(required)" while
		// the field is still empty so the obligation is explicit at rest.
		labelText += " *"
	}
	labelStyle := editorLabelStyle
	if isFocused {
		labelStyle = lipgloss.NewStyle().Bold(true).Foreground(highlight)
	}
	annotation := ""
	switch field.Type {
	case FieldSlug:
		annotation = dimStyle.Render("[gen]")
	case FieldNumber:
		annotation = dimStyle.Render("[num]")
	}
	if field.Required && m.getFieldValue(field.Name) == "" {
		annotation = dimStyle.Render("(required)")
	}
	if annotation != "" {
		gap := width - lipgloss.Width(labelText) - lipgloss.Width(annotation)
		if gap < 1 {
			gap = 1
		}
		lines = append(lines, labelStyle.Render(labelText)+strings.Repeat(" ", gap)+annotation)
	} else {
		lines = append(lines, labelStyle.Render(labelText))
	}

	val := m.getFieldValue(field.Name)

	placeholder := func(ph string) string {
		if val != "" {
			return val
		}
		return dimStyle.Render(ph)
	}

	// Interior width for editorFieldStyle: subtract border (2) + padding (2) + indent (2)
	fieldContentWidth := width - 6
	if fieldContentWidth < 10 {
		fieldContentWidth = 10
	}

	// Active field border style
	activeFieldStyle := editorFieldStyle
	if isFocused {
		activeFieldStyle = focusedFieldStyle
	}

	switch field.Type {
	case FieldString, FieldNumber:
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(placeholder("Enter "+field.Title+"...")), 2))
		}

	case FieldSlug:
		slug := val
		if slug == "" && m.selectedDoc != nil {
			slug = toSlug(m.selectedDoc.Title)
		}
		// Full width like every other field — the [gen] hint moved to the label
		// line above so all the box right edges align.
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render(slug)), 2))
		}

	case FieldText:
		rows := field.Rows
		if rows < 2 {
			rows = 3
		}
		if isEditing {
			// The textarea View() is a fixed `rows`-tall surface (it scrolls
			// internally), so the rendered box height matches the static
			// render exactly — scrollToField's line accounting stays true.
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textArea.View()), 2))
		} else {
			// Real multi-line values render verbatim; pad only UP TO the
			// schema's row count (the old code appended rows-1 newlines after
			// the value unconditionally, ballooning multi-line boxes). Cap at
			// the editing textarea's 12-row pin so static and editing heights
			// always match (review finding: >12-line values made fields below
			// jump on edit-open).
			content := capValueLines(placeholder("Enter "+field.Title+"..."), 12)
			if n := strings.Count(content, "\n") + 1; n < rows {
				content += strings.Repeat("\n", rows-n)
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
		}

	case FieldRichText:
		// Value-aware (the old render painted a fake "B I U H1…" toolbar and a
		// static "Start writing..." placeholder, never the value). Two wire
		// shapes exist (confirmed across the dev dataset):
		//   Shape A — legacy plain string: lands in Doc.Values via scalarString
		//   → shown and edited as multi-line text, like FieldText.
		//   Shape B — blocks-doc projection {"blocks":…,"html":…}: non-scalar,
		//   so absent from Doc.Values (only in Doc.Extra) → read-only preview
		//   (html stripped of tags, clamped, dim) + a Studio pointer.
		//   startFieldEdit refuses Shape B — text over the map corrupts it.
		if preview, blocks := m.richTextBlocksDoc(field.Name); blocks {
			body := preview
			if body == "" {
				body = "(no preview)"
			}
			content := dimStyle.Render(clampLines(body, maxInt(fieldContentWidth-2, 8), 6))
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
			lines = append(lines, "  "+dimStyle.Render("blocks doc — edit in Studio/Beta"))
		} else if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textArea.View()), 2))
		} else {
			// Same 12-row cap as FieldText — height parity with the editor.
			content := capValueLines(placeholder("Start writing..."), 12)
			if n := strings.Count(content, "\n") + 1; n < 3 {
				content += strings.Repeat("\n", 3-n)
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
		}

	case FieldImage:
		// Value-aware, like every other field: show the stored image URL
		// (with its asset linkage when present), or a quiet hint when unset.
		// Enter edits the URL as text — there is no drop or browse in a
		// terminal, so the old static "Drop image or browse" card was a dead
		// affordance that also hid whether an image was set at all.
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			url, assetID := parseImageValue(val)
			var content string
			switch {
			case url != "":
				content = url
				if assetID != "" {
					content += "\n" + dimStyle.Render("asset "+assetID)
				}
			case assetID != "":
				content = dimStyle.Render("asset ") + assetID
			default:
				content = dimStyle.Render("No image — enter a URL")
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(content), 2))
		}

	case FieldSelect:
		display := ""
		current := val
		if current == "" && len(field.Options) > 0 {
			current = field.Options[0]
		}
		for _, opt := range field.Options {
			if opt == current {
				display += selectActiveStyle.Render(" " + opt + " ")
			} else {
				display += dimStyle.Render(" " + opt + " ")
			}
		}
		lines = append(lines, "  "+display)

	case FieldBoolean:
		toggle := dimStyle.Render("○───")
		if val == "true" {
			toggle = statusPublished.Render("───●")
		}
		lines = append(lines, "  "+toggle)

	case FieldDatetime:
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textInput.View()), 2))
		} else {
			dv := placeholder("YYYY-MM-DD HH:MM")
			if rel := relTimeHint(val); rel != "" {
				dv += "  " + dimStyle.Render("("+rel+")")
			}
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(dv), 2))
		}

	case FieldColor:
		cv := val
		if cv == "" {
			cv = "#3b82f6" // lit-allow: color-picker DATA default (a field value, not chrome) — au-w4-cli-chrome-tokens
		}
		// The bordered value box is multi-line (border top/content/bottom), so the
		// swatch must be joined as a column beside the whole box — not concatenated
		// onto line 1 only — and the composite indented uniformly.
		var box string
		if isEditing {
			box = activeFieldStyle.Render(m.textInput.View())
		} else {
			box = activeFieldStyle.Render(cv)
		}
		// Only a strict #rgb/#rrggbb value drives a real background swatch; a
		// hostile or malformed stored value renders plain (no swatch) so it
		// can't inject escapes into the terminal (defense-in-depth parity with
		// pdrender's fieldColorRenderer).
		if tuiHexColorRe.MatchString(cv) {
			swatch := lipgloss.NewStyle().Background(lipgloss.Color(cv)).Render("    ")
			box = lipgloss.JoinHorizontal(lipgloss.Center, swatch, " ", box)
		}
		lines = append(lines, indentLines(box, 2))

	case FieldReference:
		// The stored value is the referenced doc's BARE published id (the
		// Studio's select-ref wire format). Render the resolved TITLE with the
		// id dim beside it when the cache knows it (picker fetch / editor-open
		// resolve); fall back to the bare id, and to the dim placeholder when
		// unset. Enter opens the picker (startFieldEdit's FieldReference case).
		var rv string
		title, checked := m.refTitles[val]
		switch {
		case val == "":
			rv = dimStyle.Render("Select " + field.RefType + "...")
		case title != "":
			rv = title + " " + dimStyle.Render(val)
		case checked:
			// cacheRefTitlesFor fetched the whole refType list and the target
			// was NOT in it — a broken reference (deleted target). Sanity
			// surfaces these; silently rendering the bare id hid them.
			rv = val + "  " + statusDraft.Render("⚠ not found")
		default:
			rv = val
		}
		lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(rv+"  "+dimStyle.Render(">")), 2))

	case FieldArray:
		// An array WITH data shows it (clamped raw JSON) — "[ ] No items yet"
		// over a populated dependencies list was a lie. A string-only array
		// edits in the textarea, one element per line (startFieldEdit refuses
		// mixed / non-string arrays — those stay read-only as before).
		if isEditing {
			lines = append(lines, indentLines(activeFieldStyle.Width(fieldContentWidth).Render(m.textArea.View()), 2))
		} else if body, ok := m.structuredFieldBody(field.Name, fieldContentWidth); ok {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(body), 2))
		} else {
			lines = append(lines, "  "+dimStyle.Render("[ ] no items — enter to add"))
		}

	case FieldRaw:
		// D12 (masterplan-20260425-085425): the Go TUI is read-only for v2 /
		// non-scalar field types — object, composite, arrayOf, codelist,
		// localizedText. Editing happens in the LiveView Studio.
		//
		// Read-only ≠ invisible: when the document CARRIES data for the field
		// — a task's claim {worker, epoch, resources}, its history — the raw
		// value renders as clamped pretty JSON, so the terminal shows the
		// same truth Studio's read-only panels do. Empty stays a placeholder.
		if body, ok := m.structuredFieldBody(field.Name, fieldContentWidth); ok {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(body), 2))
		} else {
			lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(dimStyle.Render("— (edit in Studio)")), 2))
		}

	default:
		lines = append(lines, indentLines(editorFieldStyle.Width(fieldContentWidth).Render(placeholder("...")), 2))
	}

	return lines
}

// rawFieldJSON renders a doc's raw NON-SCALAR field value (claim,
// dependencies, history, …) as pretty JSON for the read-only editor surface.
// Returns "" when there is no open doc, the field is absent/null/empty, or
// the bytes fail to parse — the caller then falls back to the placeholder.
// Clamped to a few lines so a deep history object cannot flood the form;
// the full value is one `bp task get` away.
// structuredFieldBody renders a non-scalar field's read-only body: an array
// of flat objects becomes the aligned mini-table (objectTable), anything else
// keeps the clamped pretty-JSON fallback. ok=false means no data at all.
func (m model) structuredFieldBody(name string, width int) (string, bool) {
	if m.selectedDoc != nil && m.selectedDoc.Extra != nil {
		if raw, ok := m.selectedDoc.Extra[name]; ok {
			if rows, tok := objectTable(raw, maxInt(width-2, 12)); tok {
				return dimStyle.Render(strings.Join(rows, "\n")), true
			}
		}
	}
	if raw := m.rawFieldJSON(name); raw != "" {
		return dimStyle.Render(raw), true
	}
	return "", false
}

func (m model) rawFieldJSON(name string) string {
	if m.selectedDoc == nil || m.selectedDoc.Extra == nil {
		return ""
	}
	raw, ok := m.selectedDoc.Extra[name]
	if !ok {
		return ""
	}
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" || trimmed == "{}" || trimmed == "[]" || trimmed == `""` {
		return ""
	}
	var v any
	if json.Unmarshal([]byte(trimmed), &v) != nil {
		return ""
	}
	pretty, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return ""
	}
	const maxRawJSONLines = 8
	lines := strings.Split(string(pretty), "\n")
	if len(lines) > maxRawJSONLines {
		lines = append(lines[:maxRawJSONLines], "…")
	}
	return strings.Join(lines, "\n")
}

// richTextBlocksDoc inspects a richText field's RAW wire value for the
// blocks-doc projection shape ({"blocks":[…],"html":"…"} — the current
// projected form for block-editor docs). A legacy plain-string body lands in
// Doc.Values via scalarString and returns ("", false) — editable as text.
// Any NON-scalar value returns (preview, true), where preview is the html
// projection stripped of tags (possibly "" when the html key is absent or the
// bytes don't parse) — the caller renders it read-only and startFieldEdit
// refuses to open an editor: a string patch over the projection map is the
// data-corruption hazard. Studio/Beta owns those docs.
func (m model) richTextBlocksDoc(name string) (string, bool) {
	if m.selectedDoc == nil || m.selectedDoc.Extra == nil {
		return "", false
	}
	raw, ok := m.selectedDoc.Extra[name]
	if !ok {
		return "", false
	}
	trimmed := strings.TrimSpace(string(raw))
	if !strings.HasPrefix(trimmed, "{") && !strings.HasPrefix(trimmed, "[") {
		return "", false // scalar (legacy string / null) — text-editable
	}
	var proj struct {
		HTML string `json:"html"`
	}
	// Best-effort preview only: an unparseable or html-less object is STILL
	// refused for editing (true) — refusal keys on non-scalar, not on shape.
	_ = json.Unmarshal([]byte(trimmed), &proj)
	return strings.TrimSpace(stripHTMLTags(proj.HTML)), true
}

// htmlEntityReplacer decodes the handful of entities the projection's html
// serializer actually emits — a preview needs readable text, not a parser.
var htmlEntityReplacer = strings.NewReplacer(
	"&amp;", "&", "&lt;", "<", "&gt;", ">", "&quot;", `"`, "&#39;", "'", "&nbsp;", " ",
)

// stripHTMLTags drops <…> tags from an html projection string and decodes the
// common entities, leaving the visible text for the read-only preview box.
func stripHTMLTags(s string) string {
	var b strings.Builder
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
		case !inTag:
			b.WriteRune(r)
		}
	}
	return htmlEntityReplacer.Replace(b.String())
}

// clampLines wraps s to width and keeps at most max physical lines, appending
// an ellipsis row when clipped — a long blocks-doc preview must never flood
// the form (mirrors rawFieldJSON's clamp discipline).
// capValueLines bounds a multi-line value to max logical lines for the
// STATIC render — the editing textarea pins its height at the same cap
// (openMultilineEditor), so static and editing renders of an over-long
// value occupy identical line spans and fields below never jump. The last
// visible line is replaced by a summary so the truncation is explicit.
func capValueLines(s string, max int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= max {
		return s
	}
	kept := lines[:max-1]
	return strings.Join(kept, "\n") + "\n… +" + fmt.Sprint(len(lines)-(max-1)) + " more lines"
}

func clampLines(s string, width, max int) string {
	wrapped := lipgloss.NewStyle().Width(width).Render(s)
	lines := strings.Split(wrapped, "\n")
	if len(lines) > max {
		lines = append(lines[:max], "…")
	}
	return strings.Join(lines, "\n")
}

// ── Preview pane ────────────────────────────────────────────────────────────

// renderPreview shows a preview of the highlighted item's content in the right
// pane — the same thing you'd see if you pressed Enter.
func (m model) renderPreview(width, height int) string {
	if m.focus.Target != FocusPane {
		return ""
	}
	pane := m.panes[m.focus.PaneIndex]
	if pane.Cursor >= len(pane.Items) {
		return ""
	}
	item := pane.Items[pane.Cursor]
	if item.IsDivider {
		return ""
	}

	// Document list item → show document detail preview. The doc-content preview
	// reuses buildEditorContent, which for a long paper produces hundreds of
	// lines; unlike the editor it is NOT viewport-clipped, and .Height() only
	// pads. Clip to the box height so this preview column can never push the
	// joined frame past the terminal. (The editor proper and the M2 read-only
	// paper-scroll surface use the viewport and are untouched.)
	if pane.IsDocList && item.Doc != nil {
		schema := findSchema(pane.Node.TypeName)
		if schema == nil {
			return ""
		}
		content := clipContentToHeight(m.buildDocPreview(item.Doc, schema, width), height)
		return paneBorder.Width(width).Height(height).Render(content)
	}

	// Structure item → show what its child contains
	if item.SourceNode == nil || item.SourceNode.Child == nil {
		return ""
	}
	child := item.SourceNode.Child

	switch child.Type {
	case NodeDocumentTypeList:
		content := m.buildDocListPreview(child, width, height)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeList:
		content := m.buildListPreview(child, width, height)
		return paneBorder.Width(width).Height(height).Render(content)
	case NodeDocument:
		// Same discrimination the doc-list preview makes: zero docs from a
		// FAILED read must not render as the blank "" a genuinely empty type
		// renders as.
		docs, outcome := m.ds.QueryResult(child.TypeName, "")
		schema := findSchema(child.TypeName)
		if len(docs) > 0 && schema != nil {
			content := clipContentToHeight(m.buildDocPreview(&docs[0], schema, width), height)
			return paneBorder.Width(width).Height(height).Render(content)
		}
		if outcome.Failed() {
			return m.renderReadFailedState(width, height)
		}
	}
	return ""
}

// buildDocPreview renders a document's fields, same as the editor content.
func (m model) buildDocPreview(doc *Doc, schema *Schema, width int) string {
	// Value receiver — safe to mutate the copy to reuse buildEditorContent.
	m.selectedDoc = doc
	m.editorSchema = schema
	// Decode the PREVIEW doc's own blocks into the copy so isCurrentPaper /
	// buildPaperContent see this doc, not whatever paper is selected in the
	// editor. syncSelectedPaper clears selectedPaperBlocks for non-papers, so a
	// non-paper preview falls through to the field-form path unchanged.
	m.syncSelectedPaper()
	return m.buildEditorContent(width)
}

// buildDocListPreview renders a list of documents for a type, like the doc list
// pane. THE CORE FIX: it no longer emits an unclamped header + 2-lines-per-doc
// (which fed an 83-doc, ~168-line body into a .Height(height) box that only pads
// and never truncates, overflowing the terminal). It builds the same Pane the
// focused doc-list pane uses and routes the interior through renderListInterior,
// so the body is line-accurately clipped to the box height before the border
// wraps it — the affordance row appears only when the list is actually clipped.
func (m model) buildDocListPreview(node *StructureNode, width, height int) string {
	var lines []string

	// Header (preview headers use width-2, matching the pre-change layout).
	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	pane := m.buildDocListPane(node)
	headerText := icon + node.Title + dimStyle.Render(" "+docListCount(pane))
	lines = append(lines, headerStyle.Width(width-2).Render(headerText))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	if len(pane.Items) == 0 && pane.ReadFailed {
		// Same refusal the focused pane renders: no rows AND no successful
		// read is a failure to report, not an empty type to announce.
		lines = append(lines, failedDocListInterior()...)
		return lipgloss.JoinVertical(lipgloss.Left, lines...)
	}
	if len(pane.Items) == 0 {
		// Preview pane isn't focusable, so it states the fact without the
		// create affordance the focused pane offers.
		lines = append(lines, emptyDocListInterior(false)...)
		return lipgloss.JoinVertical(lipgloss.Left, lines...)
	}

	// isActive=false: the preview is never the focused pane. Cursor defaults to
	// the pane's Cursor (0 for a fresh preview), so the window starts at the top.
	interior, _, _ := m.renderListInterior(pane, width-2, m.listInteriorHeight(height), false)
	lines = append(lines, interior...)
	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// buildListPreview renders a structure list's children as a summary. Like
// buildDocListPreview, it now routes the interior through renderListInterior so
// a long structure list can never overflow the box (today these are short, so
// this is behaviourally a no-op — but it removes the unclamped-emission
// divergence between the two surfaces).
func (m model) buildListPreview(node *StructureNode, width, height int) string {
	var lines []string

	icon := ""
	if node.Icon != "" {
		icon = node.Icon + " "
	}
	lines = append(lines, headerStyle.Width(width-2).Render(icon+node.Title))
	lines = append(lines, dividerStyle.Render(strings.Repeat("─", width-2)))

	pane := m.buildListPane(node)
	interior, _, _ := m.renderListInterior(pane, width-2, m.listInteriorHeight(height), false)
	lines = append(lines, interior...)
	return lipgloss.JoinVertical(lipgloss.Left, lines...)
}

// ── Empty state ──────────────────────────────────────────────────────────────

// emptyDocListInterior renders the placeholder shown when a doc-list pane holds
// no documents. The focused pane passes actionable=true to advertise the create
// key (`n` opens the title prompt); the preview pane — which can't be focused —
// passes false and just states the fact.
// docListCount renders a doc-list pane's header count. A pane whose read
// FAILED has no count to report — it prints "—" rather than "0", which would
// assert a number the failed read never produced.
func docListCount(pane Pane) string {
	if pane.ReadFailed && len(pane.Items) == 0 {
		return "—"
	}
	return fmt.Sprintf("%d", len(pane.Items))
}

// failedDocListInterior renders the placeholder shown when a doc-list pane's
// query did not succeed. It must never be confused with emptyDocListInterior:
// that one says the type is empty (a fact), this one says we could not find
// out (the absence of one). It advertises NO key — the TUI binds no refresh
// key today (the SSE stream drives DataStoreRefreshMsg), and offering one it
// cannot honour is the same class of lie the placeholder is fixing.
func failedDocListInterior() []string {
	return []string{
		"",
		dimStyle.Render("   ✕ Couldn't load documents"),
		dimStyle.Render("   the server refused or is unreachable"),
	}
}

func emptyDocListInterior(actionable bool) []string {
	lines := []string{"", dimStyle.Render("   No documents yet")}
	if actionable {
		keyStyle := lipgloss.NewStyle().Bold(true).Foreground(highlight)
		lines = append(lines, dimStyle.Render("   press ")+keyStyle.Render("n")+dimStyle.Render(" to create the first one"))
	}
	return lines
}

// renderReadFailedState is renderEmptyState's honest sibling: same centred
// chrome, but it reports that the document read failed instead of inviting a
// selection from a list that was never fetched.
func (m model) renderReadFailedState(width, height int) string {
	var lines []string
	mid := height / 2
	for i := 0; i < mid-2; i++ {
		lines = append(lines, "")
	}
	lines = append(lines, dimStyle.Render("   ✕ Couldn't load this document"))
	lines = append(lines, dimStyle.Render("   the server refused or is unreachable"))

	for len(lines) < height {
		lines = append(lines, "")
	}
	if len(lines) > height {
		lines = lines[:height]
	}
	return paneBorder.Width(width).Height(height).Render(lipgloss.JoinVertical(lipgloss.Left, lines...))
}

func (m model) renderEmptyState(width, height int) string {
	var lines []string
	mid := height / 2
	for i := 0; i < mid-2; i++ {
		lines = append(lines, "")
	}
	msg := "Select a content type to begin"
	if len(m.path) > 0 {
		msg = "Select a document to edit"
	}
	lines = append(lines, dimStyle.Render("   "+msg))

	for len(lines) < height {
		lines = append(lines, "")
	}

	content := lipgloss.JoinVertical(lipgloss.Left, lines...)
	return paneBorder.Width(width).Height(height).Render(content)
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// clipContentToHeight truncates a multi-line content string to at most height
// physical lines. Used to cap the doc-content preview column (which reuses the
// unbounded editor content) so it can never push the joined frame past the
// terminal. A no-op when the content already fits.
func clipContentToHeight(content string, height int) string {
	if height < 1 {
		height = 1
	}
	lines := strings.Split(content, "\n")
	if len(lines) <= height {
		return content
	}
	return strings.Join(lines[:height], "\n")
}

// truncate clamps s to at most max display columns, appending a "…" when it cut
// anything. Delegates to ansi.Truncate (the width-aware helper used across the
// TUI, e.g. objtable.go) so it measures display width — NOT bytes — and never
// splits a multibyte rune. The old hand-rolled version sliced by bytes
// (s[:max]), which both over-truncated this project's Norwegian titles (æøå are
// 2 bytes / 1 column) and could emit invalid UTF-8 from a mid-rune cut; it also
// overflowed the budget by 2 (`s[:max-1] + "..."` = max+2 columns).
func truncate(s string, max int) string {
	if max < 0 {
		max = 0
	}
	return ansi.Truncate(s, max, "…")
}

func toSlug(s string) string {
	s = strings.ToLower(s)
	// Rune-aware: keep any Unicode letter or digit (not just ASCII a-z/0-9), so
	// non-Latin titles (æøå, CJK, Cyrillic) survive instead of collapsing to an
	// empty or heavily-lossy slug. ASCII output is unchanged.
	s = strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return r
		}
		return '-'
	}, s)
	for strings.Contains(s, "--") {
		s = strings.ReplaceAll(s, "--", "-")
	}
	return strings.Trim(s, "-")
}
