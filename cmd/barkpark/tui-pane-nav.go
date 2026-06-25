package main

import "strings"

// scrollToField adjusts viewport to keep the focused field visible.
func (m *model) scrollToField() {
	// EXACT line offset, mirroring buildEditorContent's assembly: 4 header
	// lines, then each field's real rendered height + 1 separator. The old
	// ~3-lines-per-field approximation undershot badly on boxed fields
	// (label + 3 box rows + gap ≈ 5–6 lines), so the viewport stopped
	// following around field ~13 and the tail of a long form (a task's
	// claim/dependencies) was unreachable by keyboard.
	if !m.vpReady || m.editorSchema == nil {
		return
	}
	targetLine := 4
	fieldWidth := m.calcEditorWidth() - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	for i := 0; i < m.fieldCursor && i < len(m.editorSchema.Fields); i++ {
		// PHYSICAL lines, not slice elements: renderField returns a box as ONE
		// element with embedded newlines (label + bordered box ≈ 4–8 physical
		// rows in 2 elements), so a bare len() undercounted every boxed field
		// and the viewport stopped following partway down boxed-heavy forms.
		// The probe passes isEditing=false for every preceding field, which is
		// also EXACT while a textarea edit is live: the textarea View() is
		// height-pinned at startFieldEdit, so the editing render of a field
		// occupies the same span as its static render (pinned in
		// multiline_test.go).
		if m.fieldGroupHeader(i) != "" {
			targetLine += 2 // header + blank, mirroring buildEditorContent
		}
		targetLine += renderedLineCount(m.renderField(m.editorSchema.Fields[i], fieldWidth, false, false)) + 1
	}
	// The cursor's OWN group header (rendered before it) shifts its start too.
	if m.fieldCursor < len(m.editorSchema.Fields) && m.fieldGroupHeader(m.fieldCursor) != "" {
		targetLine += 2
	}
	if targetLine > m.viewport.YOffset+m.viewport.Height-6 {
		m.viewport.SetYOffset(targetLine - m.viewport.Height + 8)
	} else if targetLine < m.viewport.YOffset+2 {
		m.viewport.SetYOffset(maxInt(targetLine-2, 0))
	}
}

// renderedLineCount sums the PHYSICAL line count of renderField output — each
// slice element may itself be a multi-line lipgloss box render, so the slice
// length alone is not a height.
func renderedLineCount(chunks []string) int {
	n := 0
	for _, c := range chunks {
		n += strings.Count(c, "\n") + 1
	}
	return n
}

// syncPaneScroll recomputes and persists the pane's scroll offset for the
// current focused-pane box height, so cursor-follow windowing survives across
// renders. Called after every cursor move in a list pane.
func (m *model) syncPaneScroll(pane *Pane) {
	ih := m.listInteriorHeight(m.paneHeight())
	pane.Scroll = m.listScrollOffset(*pane, m.paneWidth(), ih)
}

// movePaneCursor moves the cursor by delta items (clamped, skipping dividers in
// the direction of travel) and re-persists the scroll offset. Used by pgup/pgdn.
func (m *model) movePaneCursor(pane *Pane, delta int) {
	if len(pane.Items) == 0 {
		return
	}
	target := pane.Cursor + delta
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	// Skip a landing on a divider in the direction of travel.
	step := 1
	if delta < 0 {
		step = -1
	}
	for target >= 0 && target < len(pane.Items) && pane.Items[target].IsDivider {
		target += step
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	pane.Cursor = target
	m.syncPaneScroll(pane)
}

// jumpPaneCursor sets the cursor to a specific index (clamped, skipping a
// trailing/leading divider) and re-persists the scroll offset. Used by g/G.
func (m *model) jumpPaneCursor(pane *Pane, target int) {
	if len(pane.Items) == 0 {
		return
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	// If the extreme is a divider, walk inward to the nearest real item.
	step := 1
	if target == len(pane.Items)-1 {
		step = -1
	}
	for target >= 0 && target < len(pane.Items) && pane.Items[target].IsDivider {
		target += step
	}
	if target < 0 {
		target = 0
	}
	if target > len(pane.Items)-1 {
		target = len(pane.Items) - 1
	}
	pane.Cursor = target
	m.syncPaneScroll(pane)
}
